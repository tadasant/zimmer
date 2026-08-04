# frozen_string_literal: true

# "Claude Code usage rate per active session" — how fast a single running session
# burns quota.
#
# == The definition
#
# Rate is **fraction of a quota window consumed, per active session, per hour**,
# measured over a rolling lookback.
#
#     rate = Σ(utilization consumed) / Σ(active sessions × hours elapsed)
#
# Both sums run over consecutive pairs of ClaudeAccountQuotaSnapshot rows inside
# the lookback. The numerator is the rise in `utilization_5h` (or `utilization_7d`)
# between the two readings; the denominator is the session-hours those two
# readings bracket, taken as the mean of the two `active_session_count` values
# times the elapsed hours.
#
# A rate of 0.02 means one session running for one hour consumes 2% of the
# 5-hour window.
#
# == Why pairs, and what gets dropped
#
# A pair is only counted when it is genuinely comparable. Three cases are skipped
# rather than guessed at:
#
#   * The window reset between the readings (`reset_5h` moved, or utilization
#     fell). Anthropic's counters are sliding windows: they go DOWN on their own.
#     Differencing across that boundary would record negative usage, and clamping
#     it to zero would silently understate the rate instead. Skip the pair.
#   * Either reading predates the `active_session_count` column, so the pair has
#     no denominator.
#   * Nothing was running (`0` session-hours). Usage with no sessions to
#     attribute it to is real but unattributable — dividing by zero here would
#     produce an infinite rate that then dominates the forecast.
#
# `#sample_count` reports how many pairs survived, and every consumer is expected
# to treat a rate built from too few pairs as absent rather than as zero. A
# missing rate must never read as "no usage" — see SpotGateService, which fails
# open on exactly that condition.
#
# == Where the samples come from
#
# QuotaSnapshotService writes a row on every quota reading, and
# ClaudeUsageSamplerJob adds a scheduled reading for the account that is actually
# serving. Before that job existed the only *scheduled* readings were of
# `quota_exceeded` accounts, which is precisely the population whose utilization
# is pinned and therefore useless as a rate signal.
class ClaudeUsageRateService
  # How far back to look for sample pairs. Long enough to survive a couple of
  # missed samples, short enough that the number still describes what is
  # happening now rather than what happened this morning.
  DEFAULT_LOOKBACK = 6.hours

  # Below this many usable pairs the rate is reported but flagged `sufficient?
  # => false`. Two pairs is not a trend; it is two readings and a coincidence.
  MIN_SAMPLES = 3

  # A gap longer than this between two readings is not a measurement, it is two
  # measurements with a hole between them — the session count almost certainly
  # changed several times in the interval and the mean is meaningless.
  MAX_PAIR_GAP = 90.minutes

  Result = Data.define(:rate_5h, :rate_7d, :sample_count, :session_hours, :lookback, :window_start) do
    # Whether there is enough evidence to forecast from.
    def sufficient?
      sample_count >= MIN_SAMPLES && session_hours.positive? && !rate_5h.nil?
    end

    # Percent of the 5-hour window one session consumes per hour.
    def rate_5h_pct
      rate_5h ? rate_5h * 100 : nil
    end

    def rate_7d_pct
      rate_7d ? rate_7d * 100 : nil
    end

    def to_h
      {
        rate_5h_per_session_hour: rate_5h,
        rate_7d_per_session_hour: rate_7d,
        rate_5h_pct_per_session_hour: rate_5h_pct,
        rate_7d_pct_per_session_hour: rate_7d_pct,
        sample_count: sample_count,
        session_hours_observed: session_hours,
        lookback_hours: lookback / 3600.0,
        window_start: window_start&.iso8601,
        sufficient: sufficient?
      }
    end
  end

  class << self
    # Sessions burning Claude Code quota right now.
    #
    # `running` only: a `waiting` session has no process, and a `needs_input` one
    # is idle at a prompt. Runtime-scoped because a Codex session spends nothing
    # against a Claude account, and counting it would deflate the per-session rate
    # for every Claude session in the same window.
    def active_session_count
      Session.where(status: :running, agent_runtime: "claude_code").count
    rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
      0
    end

    def call(lookback: DEFAULT_LOOKBACK, now: Time.current)
      new(lookback: lookback, now: now).call
    end
  end

  def initialize(lookback: DEFAULT_LOOKBACK, now: Time.current)
    @lookback = lookback
    @now = now
  end

  def call
    window_start = @now - @lookback
    consumed_5h = 0.0
    consumed_7d = 0.0
    # One denominator per window, not one shared. The 5-hour window resets every
    # five hours and the weekly one does not, so inside a 6-hour lookback a pair
    # routinely straddles a 5h reset while the 7d counter runs straight through.
    # Sharing a denominator would credit those hours to the 5h rate while its
    # numerator got nothing, understating it exactly when it matters most.
    session_hours_5h = 0.0
    session_hours_7d = 0.0
    samples = 0

    snapshots_by_account(window_start).each_value do |series|
      series.each_cons(2) do |earlier, later|
        hours = (later.created_at - earlier.created_at) / 3600.0
        next unless hours.positive?
        next if hours > MAX_PAIR_GAP / 3600.0

        pair_session_hours = mean_active_sessions(earlier, later)&.*(hours)
        next if pair_session_hours.nil? || pair_session_hours <= 0

        rise_5h = positive_rise(earlier.utilization_5h, later.utilization_5h, earlier.reset_5h, later.reset_5h)
        rise_7d = positive_rise(earlier.utilization_7d, later.utilization_7d, earlier.reset_7d, later.reset_7d)
        next if rise_5h.nil? && rise_7d.nil?

        if rise_5h
          consumed_5h += rise_5h
          session_hours_5h += pair_session_hours
        end
        if rise_7d
          consumed_7d += rise_7d
          session_hours_7d += pair_session_hours
        end
        samples += 1
      end
    end

    Result.new(
      rate_5h: session_hours_5h.positive? ? consumed_5h / session_hours_5h : nil,
      rate_7d: session_hours_7d.positive? ? consumed_7d / session_hours_7d : nil,
      sample_count: samples,
      # Reported as the 5-hour window's observed span, which is the one the
      # dashboard shows the rate for.
      session_hours: session_hours_5h,
      lookback: @lookback,
      window_start: window_start
    )
  end

  private

  def snapshots_by_account(window_start)
    ClaudeAccountQuotaSnapshot
      .where(created_at: window_start..@now)
      .order(:claude_account_id, :created_at)
      .to_a
      .group_by(&:claude_account_id)
  end

  # Mean sessions running across the pair. nil when either reading predates the
  # column — a pair with no denominator is dropped, not assumed to be 1.
  def mean_active_sessions(earlier, later)
    a = earlier.active_session_count
    b = later.active_session_count
    return nil if a.nil? || b.nil?

    (a + b) / 2.0
  end

  # The rise in a utilization counter between two readings, or nil when the pair
  # straddles a window reset and therefore measures nothing.
  def positive_rise(earlier_value, later_value, earlier_reset, later_reset)
    return nil if earlier_value.nil? || later_value.nil?
    # The reset timestamp moving forward means a new window opened between the
    # readings, so `later_value` counts against a different allowance.
    return nil if earlier_reset && later_reset && later_reset > earlier_reset

    delta = later_value - earlier_value
    # A fall with no reset-time change is the sliding window ageing events out.
    # It is not negative usage, and it is not zero usage either — we simply
    # cannot see what was spent. Drop it.
    return nil if delta.negative?

    delta
  end
end
