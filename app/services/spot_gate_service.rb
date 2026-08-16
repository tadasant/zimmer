# frozen_string_literal: true

# Decides whether a spot session may start right now.
#
# == The rule: fill to the ceiling, then hold
#
# The gate is a saturating controller, not a cautious guard. The thresholds on
# /quotas are a **target to reach**, not a cliff to stay well clear of: idle
# should mean "the windows are at 80%", never "we were being careful". So the
# question it answers is not "would one more session be risky" but:
#
#     how many spot sessions can run AT ONCE and land the window on its ceiling
#     by the time this decision is re-made?
#
#     capacity = (ceiling − utilization now) / (rate × control interval)
#
# `rate` is ClaudeUsageRateService's per-session-hour figure and the control
# interval is CONTROL_INTERVAL — how long a decision has to stay good, because a
# held session re-checks that often and every new session re-evaluates from
# scratch. A session starts while the running fleet plus itself fits inside the
# capacity, so a queue of waiting work fills the fleet up to capacity in
# parallel and the windows climb to their ceilings quickly.
#
# Priority sessions are never consulted about any of this. They start.
#
# == Why capacity, and not "does one more session breach"
#
# The old rule projected the burn of `fleet + 1` sessions across every remaining
# hour of the window and held if that crossed the ceiling. Two things made it
# structurally incapable of parallelism:
#
#   * The session count multiplied a projection run out to the window's reset.
#     With 24 hours left on a weekly window, one session's worth of burn
#     extrapolated to 53% of the whole allowance — so the FIRST admission
#     breached and every later candidate was held. Work could only ever trickle.
#   * It was harshest right after a window opened, when the hours remaining were
#     largest, which is exactly when there is the most room to spend.
#
# Bounding the projection to the control interval fixes both: the forecast is a
# claim about the next ten minutes, which is the only claim a rate measured over
# a few hours can actually support, and it is the horizon over which the
# decision is allowed to be wrong before being re-made.
#
# == Why the pool, not the serving account
#
# Zimmer runs a pool of Claude Code accounts and rotates automatically when the
# serving one is refused (AccountRotationService). "Can this deployment absorb
# more work" is therefore a question about the pool: holding a queue because the
# current account is at 69% while three spares sit under 50% starves the work
# for capacity that is right there. The gate sizes every usable account and uses
# the roomiest — the one the pool would lean on next.
#
# == One accelerator, two brakes
#
# The capacity rule above is the accelerator: climb to the target fast. Two
# brakes bound it, and both are checked BEFORE the forecast, because both are
# statements about measured fact rather than about extrapolation.
#
#   * **The hard stop.** When a window has actually reached its target, spot work
#     stops until the number comes back down. The forecast governs the ramp
#     toward the target; this governs arrival at it, and it holds even when the
#     rate is unmeasurable — the one case where the forecast fails open.
#   * **The fleet cap.** `spot_max_concurrent_sessions` on /quotas (10 by
#     default) bounds how many sessions run at once, which is what bounds how
#     fast the quota can be spent. EVERY running session counts against it,
#     priority included, but only spot sessions are held by it: priority work is
#     meant to crowd spot work out of the slots.
#
# Neither brake flaps. Utilization dipping a hair under the target does not
# release the queue, because capacity is the room for a whole session's burn over
# the control interval — at production's measured rate, about seven points of the
# 5-hour window. The band is derived from the burn rather than picked, so it
# widens exactly when sessions are expensive and narrows when they are cheap.
#
# == "Hold" means DEFER, not refuse
#
# A held session is not rejected and nothing is lost. It stays `waiting` — the
# status Zimmer already uses for "created, not started" — and AgentSessionJob
# re-enqueues itself to re-check. When capacity opens, or simply when the
# 5-hour window resets, the same job starts the session normally. SpotSessionHold
# also bounds how long that can go on, so a queue cannot starve indefinitely
# behind a window that never clears.
#
# == Fail-open
#
# Every uncertain condition allows the session: gating off, no rate signal yet,
# no quota snapshots, an unreadable AppSetting. A monitoring gap must not become
# an outage of all automated work. `#reason` names which case applied so the UI
# and MCP can say so rather than showing a bare "allowed".
class SpotGateService
  # How long a decision has to stay good. A held session re-checks after this
  # long, so it is also the horizon the forecast is bounded to: the gate only has
  # to be right until it next re-decides.
  CONTROL_INTERVAL = 10.minutes

  Forecast = Data.define(:current, :projected, :threshold, :horizon_hours, :capacity, :breached, :at_limit) do
    def breached? = breached

    # The window has actually reached its target. Measured, not forecast — this
    # is the hard stop, and it holds whether or not a rate could be measured.
    def at_limit? = at_limit
    def current_pct = current ? current * 100 : nil
    def projected_pct = projected ? projected * 100 : nil
    def threshold_pct = threshold ? threshold * 100 : nil

    def to_h
      {
        current_pct: current_pct,
        projected_pct: projected_pct,
        threshold_pct: threshold_pct,
        horizon_hours: horizon_hours,
        capacity: capacity,
        breached: breached?,
        at_limit: at_limit?
      }
    end
  end

  # One account's answer, so the pool can be compared account by account.
  AccountForecast = Data.define(:email, :five_hour, :weekly) do
    # Window label => forecast, skipping any window there is nothing to forecast
    # from. Labelled rather than positional because two windows can hold equal
    # values and Data compares by value — telling them apart by identity would
    # occasionally name the wrong one as the reason a session was held.
    def labelled = { "5-hour" => five_hour, "weekly" => weekly }.compact

    def windows = labelled.values

    def breaches = labelled.select { |_label, window| window.breached? }

    def at_limit = labelled.select { |_label, window| window.at_limit? }

    def at_limit? = at_limit.any?

    # Concurrent sessions this account can carry: the tighter of its two windows.
    # A window with no measurable burn places no bound, and an account with no
    # forecastable window at all is unbounded — the fail-open case.
    def capacity
      bounds = windows.filter_map(&:capacity)
      return Float::INFINITY if bounds.empty?

      bounds.min
    end

    # What this account may actually carry: nothing at all once a window has
    # reached its target, however much the forecast thinks would fit.
    def admissible_capacity = at_limit? ? 0 : capacity
  end

  Decision = Data.define(:allowed, :reason, :detail, :forecast_5h, :forecast_7d, :rate,
                         :active_sessions, :forecast_sessions, :capacity, :fleet_cap,
                         :accounts_considered, :account_email) do
    def allowed? = allowed
    def held? = !allowed

    def to_h
      {
        allowed: allowed?,
        reason: reason,
        detail: detail,
        active_sessions: active_sessions,
        forecast_sessions: forecast_sessions,
        capacity: capacity,
        fleet_cap: fleet_cap,
        accounts_considered: accounts_considered,
        account_email: account_email,
        forecast_5h: forecast_5h&.to_h,
        forecast_7d: forecast_7d&.to_h,
        usage_rate: rate&.to_h
      }
    end
  end

  # The answer for a priority session: it starts, and nothing about quota was
  # consulted to decide that.
  ALWAYS_ALLOWED = Decision.new(
    allowed: true, reason: "priority",
    detail: "Priority sessions are never gated on quota headroom.",
    forecast_5h: nil, forecast_7d: nil, rate: nil,
    active_sessions: nil, forecast_sessions: nil, capacity: nil, fleet_cap: nil,
    accounts_considered: nil, account_email: nil
  ).freeze

  class << self
    # Whether `session` may start now. Priority sessions short-circuit without
    # touching the database beyond their own genesis.
    def allow_start?(session)
      start_decision(session).allowed?
    end

    # The Decision for starting `session`, and the single seam the production
    # path goes through — SpotSessionHold calls this, so `allow_start?` is a read
    # of live behavior rather than a parallel implementation that could drift.
    #
    # A priority session is answered without touching the quota tables at all.
    def start_decision(session)
      return ALWAYS_ALLOWED unless session.spot?

      current_decision
    end

    # The one reading every surface shows: what a spot session starting right now
    # would actually get. `/quotas` and `get_spot_policy` both call this, so the
    # page and the tool cannot answer the same question differently — the bug
    # that let the card show "headroom available" beside "would be held".
    #
    # `candidate_sessions: 1` counts the session being asked about: the fleet
    # does not include it yet, and a capacity check has to be about the fleet
    # this decision would produce.
    def current_decision(now: Time.current)
      evaluate(now: now, candidate_sessions: 1)
    end

    def evaluate(now: Time.current, candidate_sessions: 0)
      new(now: now, candidate_sessions: candidate_sessions).evaluate
    end

    # The operator's ceiling on how many sessions run at once, from /quotas.
    # Every running session counts against it; only spot ones are held by it.
    def fleet_cap
      AppSetting.current.spot_max_concurrent_sessions
    end
  end

  def initialize(now: Time.current, candidate_sessions: 0)
    @now = now
    @candidate_sessions = candidate_sessions
  end

  def evaluate
    setting = AppSetting.current

    unless setting.spot_gating_enabled
      return allow("gating_disabled", "Spot gating is turned off — spot sessions start like any other.")
    end

    rate = ClaudeUsageRateService.call(now: @now)
    # A rate too thin to forecast from still leaves the two measured brakes below
    # standing: it costs the ramp, not the stop.
    usable_rate = rate.sufficient? ? rate : nil

    accounts = account_forecasts(rate: usable_rate, setting: setting)
    if accounts.empty?
      return allow("no_snapshot", "No Claude Code quota reading available to forecast from.", rate: rate)
    end

    # The roomiest account is the one the pool would lean on, so it is both the
    # decision and the forecast worth reporting. Ties break toward an account that
    # has not reached a target, so the reason names the right thing.
    best = accounts.max_by { |a| [ a.admissible_capacity, a.at_limit? ? 0 : 1 ] }
    fleet_cap = setting.spot_max_concurrent_sessions
    capacity = [ best.admissible_capacity, fleet_cap ].min

    # Brake 1: a window is actually at its target. Measured, so it applies even
    # with no usable rate — the case the forecast fails open on.
    return at_limit(best, accounts, rate, fleet_cap) if best.at_limit?
    # Brake 2: the fleet is full. Every running session counts, priority
    # included; only spot sessions are held by it.
    return at_fleet_cap(best, accounts, rate, fleet_cap) if forecast_sessions > fleet_cap

    unless rate.sufficient?
      return allow("insufficient_data", insufficient_data_detail(rate), rate: rate, best: best, accounts: accounts,
                   fleet_cap: fleet_cap)
    end

    if forecast_sessions <= capacity
      admitted(best, accounts, rate, capacity, fleet_cap)
    else
      held(best, accounts, rate, capacity, fleet_cap)
    end
  # StandardError, deliberately broad. ActiveRecord::ConnectionNotEstablished and
  # its ConnectionTimeoutError subclass descend from AdapterError, NOT from
  # StatementInvalid — and pool exhaustion is very reachable with a fleet of
  # concurrent AgentSessionJobs. Anything narrower lets the exception escape into
  # AgentSessionJob, which marks the session `failed`. A spot session must never
  # be failed by the thing whose entire promise is that it only defers.
  rescue StandardError => e
    Rails.logger.warn("[SpotGateService] Could not evaluate (#{e.class}: #{e.message}); allowing the session")
    allow("unavailable", "Could not evaluate the spot gate (#{e.class}); allowing the session.")
  end

  private

  def active_sessions = @active_sessions ||= ClaudeUsageRateService.active_session_count

  # The fleet this decision would produce: what is running, plus the session
  # being asked about.
  def forecast_sessions = active_sessions + @candidate_sessions

  def allow(reason, detail, rate: nil, best: nil, accounts: nil, fleet_cap: nil)
    Decision.new(
      allowed: true, reason: reason, detail: detail,
      forecast_5h: best&.five_hour, forecast_7d: best&.weekly, rate: rate,
      active_sessions: active_sessions, forecast_sessions: forecast_sessions,
      capacity: nil, fleet_cap: fleet_cap,
      accounts_considered: accounts&.size, account_email: best&.email
    )
  end

  def admitted(best, accounts, rate, capacity, fleet_cap)
    Decision.new(
      allowed: true,
      reason: "within_capacity",
      detail: "Room for #{capacity} concurrent spot #{'session'.pluralize(capacity)} and " \
              "#{active_sessions} running#{on_account(best, accounts)}: #{projection_phrase(best)}. " \
              "#{pool_phrase(accounts)}".squish,
      forecast_5h: best.five_hour, forecast_7d: best.weekly, rate: rate,
      active_sessions: active_sessions, forecast_sessions: forecast_sessions,
      capacity: capacity, fleet_cap: fleet_cap,
      accounts_considered: accounts.size, account_email: best.email
    )
  end

  def held(best, accounts, rate, capacity, fleet_cap)
    Decision.new(
      allowed: false,
      reason: "at_capacity",
      detail: "Holding spot sessions: the fleet is at the #{capacity} concurrent " \
              "#{'session'.pluralize(capacity)} quota can carry over the next #{horizon_label} " \
              "(#{active_sessions} running). #{closest_phrase(best, accounts)} " \
              "Priority sessions are unaffected.".squish,
      forecast_5h: best.five_hour, forecast_7d: best.weekly, rate: rate,
      active_sessions: active_sessions, forecast_sessions: forecast_sessions,
      capacity: capacity, fleet_cap: fleet_cap,
      accounts_considered: accounts.size, account_email: best.email
    )
  end

  # The hard stop: a window has actually reached its target, so spot work waits
  # for the number to come down rather than for a forecast to improve.
  def at_limit(best, accounts, rate, fleet_cap)
    reached = best.at_limit.map do |label, window|
      "#{label} window at #{window.current_pct.round}% of its #{window.threshold_pct.round}% target"
    end

    Decision.new(
      allowed: false,
      reason: "at_utilization_limit",
      detail: "Holding spot sessions: #{pool_reach_phrase(accounts)} #{reached.join(' and ')} " \
              "on #{best.email}. Spot work waits for utilization to come down, not for a forecast. " \
              "Priority sessions are unaffected.".squish,
      forecast_5h: best.five_hour, forecast_7d: best.weekly, rate: rate,
      active_sessions: active_sessions, forecast_sessions: forecast_sessions,
      capacity: 0, fleet_cap: fleet_cap,
      accounts_considered: accounts.size, account_email: best.email
    )
  end

  # The fleet cap: all the slots are taken. Priority sessions occupy slots and
  # are never held by this — a fleet of priority work crowding spot work out is
  # the intent, not a bug.
  def at_fleet_cap(best, accounts, rate, fleet_cap)
    Decision.new(
      allowed: false,
      reason: "fleet_at_cap",
      detail: "Holding spot sessions: #{active_sessions} of #{fleet_cap} session slots are taken. " \
              "Every running session counts, priority included — priority work is meant to crowd spot " \
              "work out. Raise the limit on /quotas to widen it.".squish,
      forecast_5h: best.five_hour, forecast_7d: best.weekly, rate: rate,
      active_sessions: active_sessions, forecast_sessions: forecast_sessions,
      capacity: fleet_cap, fleet_cap: fleet_cap,
      accounts_considered: accounts.size, account_email: best.email
    )
  end

  def pool_reach_phrase(accounts)
    return "the" if accounts.size < 2

    "every usable Claude Code account has reached a target, the roomiest with its"
  end

  def closest_phrase(best, accounts)
    breaches = best.breaches.map do |label, window|
      "#{label} window forecast at #{window.projected_pct.round}% (limit #{window.threshold_pct.round}%)"
    end
    return "" if breaches.empty?

    prefix = accounts.size > 1 ? "Roomiest account is #{best.email} — " : ""
    "#{prefix}#{breaches.join(' and ')} at #{forecast_sessions} sessions."
  end

  def insufficient_data_detail(rate)
    "Not enough quota samples yet to forecast (#{rate.sample_count} usable " \
      "#{'pair'.pluralize(rate.sample_count)} over #{rate.session_hours.round(2)} observed session-hours " \
      "in the last #{(rate.lookback / 3600).round}h; holding work needs at least " \
      "#{ClaudeUsageRateService::MIN_SAMPLES} pairs and " \
      "#{ClaudeUsageRateService::MIN_SESSION_HOURS} session-hours). " \
      "Spot sessions run until the rate is measurable."
  end

  def on_account(best, accounts) = accounts.size > 1 ? " on #{best.email}" : ""

  def pool_phrase(accounts)
    return "" if accounts.size < 2

    "Roomiest of #{accounts.size} usable Claude Code accounts."
  end

  def projection_phrase(best)
    phrases = best.labelled.map do |label, window|
      "#{label} #{window.projected_pct.round}% against a #{window.threshold_pct.round}% limit"
    end
    return "no window has a known reset time to project against" if phrases.empty?

    "at #{forecast_sessions} #{'session'.pluralize(forecast_sessions)}, #{phrases.join(' and ')} " \
      "#{horizon_label} out"
  end

  def horizon_label = "#{(CONTROL_INTERVAL / 60).round} minutes"

  # Every account the pool could actually serve from. `available` is the serve
  # pool AccountRotationService picks from — active status, credentials on file —
  # so an account already marked quota_exceeded does not get a vote on whether
  # there is room. When nothing is available the pool is spent, and the serving
  # account's own reading is what is left to forecast from; that keeps a fully
  # exhausted deployment holding rather than falling through to "no snapshot".
  def pool_accounts
    scope = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME)
    available = scope.available.to_a
    return available if available.any?

    [ scope.find_by(is_current: true) ].compact
  end

  def account_forecasts(rate:, setting:)
    pool_accounts.filter_map do |account|
      snapshot = account.latest_snapshot
      next if snapshot.nil?

      AccountForecast.new(
        email: account.email,
        five_hour: forecast(
          current: ClaudeAccountQuotaSnapshot.effective_utilization(snapshot.utilization_5h, snapshot.reset_5h),
          reset_at: snapshot.reset_5h, rate: rate&.rate_5h,
          threshold_pct: setting.spot_gate_five_hour_threshold_pct
        ),
        weekly: forecast(
          current: ClaudeAccountQuotaSnapshot.effective_utilization(snapshot.utilization_7d, snapshot.reset_7d),
          reset_at: snapshot.reset_7d, rate: rate&.rate_7d,
          threshold_pct: setting.spot_gate_weekly_threshold_pct
        )
      )
    end
  end

  def forecast(current:, reset_at:, rate:, threshold_pct:)
    return nil if current.nil?
    # No reset time means we do not know whether this window is about to clear,
    # and projecting against a counter that may be seconds from resetting would
    # manufacture a breach out of a missing field. An unknown horizon is a
    # monitoring gap, and a monitoring gap allows.
    return nil if reset_at.nil?

    threshold = threshold_pct.to_f / 100.0
    hours = horizon_hours(reset_at)
    burn = (rate || 0.0) * hours
    projected = current + (burn * forecast_sessions)

    Forecast.new(
      current: current,
      projected: projected,
      threshold: threshold,
      horizon_hours: hours,
      capacity: window_capacity(threshold - current, burn),
      breached: projected > threshold,
      at_limit: current >= threshold
    )
  end

  # Concurrent sessions this window can carry before it lands on its ceiling.
  # No measurable burn over the horizon means the window bounds nothing — a
  # window that resets inside the interval is in that position too, since what
  # is spent against it stops mattering the moment it clears.
  def window_capacity(headroom, burn)
    return nil unless burn.positive?

    [ (headroom / burn).floor, 0 ].max
  end

  # The lookahead: how long this decision has to stay good, never past the point
  # where the window resets and the number being forecast stops existing.
  def horizon_hours(reset_at)
    hours = (reset_at - @now) / 3600.0
    return 0.0 if hours.negative?

    [ hours, CONTROL_INTERVAL / 3600.0 ].min
  end
end
