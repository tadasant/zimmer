# frozen_string_literal: true

# The unified capacity model: how much capacity a quota window holds, how much
# of it is reserved for priority work, and how fast spot work may consume the
# rest so that it lands on 100% exactly as the window rolls over.
#
# One object answers all three, and every surface reads this one — the spot
# gate, the /quotas card, `get_spot_policy`. A page that showed "$412 remaining"
# beside a gate that had decided on something else would be worse than showing
# nothing.
#
# == The three quantities
#
#   capacity      what a full window is worth, in Opus dollars
#                 (QuotaCapacityEstimate, calibrated from actual spend)
#   reserve       capacity * the reserve percentage the operator set. Spot work
#                 must never touch this; it is what priority sessions spend out
#                 of when they arrive unannounced.
#   spot budget   capacity - reserve. This is what an infinite queue of spot
#                 work is EXPECTED to consume in full, every window.
#
# The operator sets a percentage and reads a dollar figure. That is the whole
# point of the split: a percentage is what a human can reason about setting
# ("keep a fifth back"), and dollars are what the scheduler can reason about
# spending.
#
# == The two conditions
#
# Admitting a spot session has to satisfy both, and they guard different things.
#
#   1. THE CAP. `spent + (fleet burn + this session's burn) * lookahead` must
#      stay inside the spot budget. This is what protects the reserve, and it is
#      absolute: it does not care what time it is.
#
#   2. THE PACE. The fleet's burn rate, including the candidate, must stay under
#      what the window can sustain from here — `remaining spot budget / time
#      left`. This is the smooth just-in-time curve.
#
# Condition 2 is self-correcting in both directions, which is what makes the
# curve smooth rather than a cliff. Spend below the curve and the sustainable
# rate rises, admitting more work; run ahead of it and the rate falls, holding
# work back until the window catches up. Because the numerator is what is LEFT
# and the denominator is the time left to spend it in, a window that has been
# quiet does not stay quiet — it releases faster — and a window that burned hard
# early throttles rather than stopping dead. At the far end of the window the
# rate rises steeply, which is the correct behavior for a use-it-or-lose-it
# allowance; condition 1 is what stops that from eating the reserve.
#
# == "SOME work at all times of day"
#
# There is one exception to condition 2, and it exists because a session is not
# infinitely divisible. If the sustainable rate is below what a single session
# burns, condition 2 alone would admit nothing, ever, and leave the whole spot
# budget unspent — the opposite of what this model is for. So when NOTHING is
# running, the pace condition is waived and only the cap applies. One session
# runs, gets ahead of the curve, and the next admission is held until the curve
# catches up: a duty cycle rather than an outage. Work happens at every hour of
# the day, and the reserve is still never touched.
#
# It keys on the whole fleet being idle, not on spot sessions being idle:
# priority work running IS work happening, and it spends against the same
# window.
#
# == Degrading honestly
#
# With no usable dollar estimate — a fresh install, or a calibration cron that
# has stopped — the model reasons in FRACTIONS OF A WINDOW instead of dollars.
# Every quantity means the same thing on a 0..1 scale, the cap and the pacing
# curve work identically, and only the burn-rate half of the arithmetic is
# unavailable (a rate in $/min cannot be compared to a rate in window-fractions
# per minute without the very number that is missing). `dollars?` says which
# mode a window is in, and every surface prints it.
class QuotaCapacityModel
  # How far ahead the cap looks when projecting what the running fleet will
  # spend before anyone checks again. It is SpotGateService::RETRY_DELAY,
  # because that is exactly how long a decision has to hold for — but stated
  # here rather than read from there, so the two classes do not reference each
  # other's constants at load time. A test asserts they are equal, which is what
  # keeps them from drifting.
  LOOKAHEAD = 10.minutes

  # One window's capacity, reserve, pacing curve and the decision they imply.
  #
  # Every `_units` figure is dollars when `dollars?`, and fractions of the window
  # (0..1, where 1.0 is the whole window) otherwise. The `_usd` readers return
  # nil in the degraded mode rather than handing a fraction to something that
  # will render it with a dollar sign.
  class Window
    attr_reader :key, :utilization, :reserve_pct, :seconds_remaining, :capacity_usd, :estimate

    # @param key [String] QuotaCapacityEstimate::FIVE_HOUR or WEEKLY
    # @param utilization [Float] the pool's average utilization, 0..1
    # @param reserve_pct [Integer] percentage of the window held for priority work
    # @param seconds_remaining [Integer, nil] until this window rolls over; nil
    #   when no account could say, which disables the pacing curve
    # @param capacity_usd [Float, nil] nil puts the window in fraction mode
    # @param margin_pct [Numeric] percentage points of the window to hold back
    #   on top of the reserve. Non-zero only for resume decisions.
    # @param estimate [QuotaCapacityEstimate, nil] provenance, for display
    def initialize(key:, utilization:, reserve_pct:, seconds_remaining:,
                   capacity_usd: nil, margin_pct: 0, estimate: nil)
      @key = key
      @utilization = utilization.to_f.clamp(0.0, 1.0)
      @reserve_pct = reserve_pct.to_i.clamp(0, 100)
      @seconds_remaining = seconds_remaining&.clamp(0, window_seconds)
      @capacity_usd = capacity_usd
      @margin_pct = margin_pct.to_f.clamp(0.0, 100.0)
      @estimate = estimate
    end

    def label = QuotaCapacityEstimate.label(key)
    def window_seconds = QuotaCapacityEstimate.window_seconds(key)

    # True when this window's arithmetic is in dollars rather than in fractions
    # of the window. Every surface prints this, because "$412 left" and "31% of
    # the window left" are different claims and only one of them is available.
    def dollars? = !capacity_usd.nil?

    # The scale everything below is measured in: one window.
    def capacity_units = dollars? ? capacity_usd : 1.0

    def spent_units = capacity_units * utilization

    # Held back for priority work, plus the resume margin when one applies. The
    # margin is not part of the operator's reserve — it is the distance a paused
    # session has to see before it restarts, so it is added here rather than
    # folded into `reserve_pct`, which is what the page renders.
    def reserve_units = capacity_units * ((reserve_pct + @margin_pct) / 100.0)

    # What spot work is expected to consume in full before this window rolls.
    def spot_budget_units = [ capacity_units - reserve_units, 0.0 ].max

    def remaining_spot_units = [ spot_budget_units - spent_units, 0.0 ].max
    def remaining_units = [ capacity_units - spent_units, 0.0 ].max

    # The dollar readers. Nil in fraction mode: a caller that wants money must
    # be able to tell "we do not know" from "zero".
    def spent_usd = dollars? ? spent_units : nil
    def reserve_usd = dollars? ? capacity_usd * (reserve_pct / 100.0) : nil
    def spot_budget_usd = dollars? ? spot_budget_units : nil
    def remaining_spot_usd = dollars? ? remaining_spot_units : nil
    def remaining_usd = dollars? ? remaining_units : nil

    # How far into the window we are, 0..1. Nil when nothing could say when the
    # window rolls, which is what turns the pacing curve off.
    def elapsed_fraction
      return nil if seconds_remaining.nil?

      ((window_seconds - seconds_remaining).to_f / window_seconds).clamp(0.0, 1.0)
    end

    # The rate at which the remaining spot budget can be consumed and still land
    # on exactly 100% as the window rolls over. Nil when the rollover time is
    # unknown; Float::INFINITY in the last moments, which condition 1 bounds.
    def sustainable_units_per_minute
      return nil if seconds_remaining.nil?
      return Float::INFINITY if seconds_remaining.zero?

      remaining_spot_units / (seconds_remaining / 60.0)
    end

    # Condition 1 — the cap. Would running at `burn_units_per_minute` for the
    # lookahead take total spend past the non-reserved budget?
    #
    # @param burn_units_per_minute [Float] fleet + candidate, in this window's units
    def within_cap?(burn_units_per_minute)
      projected_spend_units(burn_units_per_minute) <= spot_budget_units
    end

    # Condition 2 — the pace. Is that burn rate inside what the window can
    # sustain from here? True when the rollover time is unknown, because a curve
    # with no time axis constrains nothing and condition 1 still applies.
    def within_pace?(burn_units_per_minute)
      rate = sustainable_units_per_minute
      return true if rate.nil?

      burn_units_per_minute <= rate
    end

    # What total spend will be by the next decision, if the fleet keeps burning
    # at this rate. The cap is tested against this rather than against `spent`
    # alone, which is what makes a session's own projected spend part of the
    # question rather than something noticed after the fact.
    def projected_spend_units(burn_units_per_minute)
      spent_units + (burn_units_per_minute * (LOOKAHEAD / 60.0))
    end

    def to_h
      {
        window: key,
        label: label,
        utilization_pct: utilization * 100,
        reserve_pct: reserve_pct,
        denominated_in_dollars: dollars?,
        capacity_usd: capacity_usd,
        spent_usd: spent_usd,
        reserve_usd: reserve_usd,
        spot_budget_usd: spot_budget_usd,
        remaining_usd: remaining_usd,
        remaining_spot_usd: remaining_spot_usd,
        seconds_remaining: seconds_remaining,
        elapsed_fraction: elapsed_fraction,
        sustainable_usd_per_minute: dollars? ? sustainable_units_per_minute : nil
      }
    end
  end

  class << self
    # Both windows, built from the pool's reading and the operator's policy.
    #
    # @param measure [ClaudeAccountPool::Measure]
    # @param setting [AppSetting]
    # @param margin_pct [Numeric] see Window#initialize
    # @return [Hash{String => Window}] keyed by QuotaCapacityEstimate window key,
    #   with a window omitted when the pool has no utilization reading for it
    def windows(measure:, setting:, margin_pct: 0)
      estimates = QuotaCapacityEstimate.table

      {
        QuotaCapacityEstimate::FIVE_HOUR => [ measure.five_hour, setting.spot_reserve_five_hour_pct, measure.five_hour_seconds_remaining ],
        QuotaCapacityEstimate::WEEKLY => [ measure.weekly, setting.spot_reserve_weekly_pct, measure.weekly_seconds_remaining ]
      }.filter_map do |key, (utilization, reserve_pct, seconds_remaining)|
        next if utilization.nil?

        estimate = estimates[key]
        [ key, Window.new(
          key: key, utilization: utilization, reserve_pct: reserve_pct,
          seconds_remaining: seconds_remaining,
          capacity_usd: estimate&.usable? ? estimate.capacity_usd : nil,
          margin_pct: margin_pct, estimate: estimate
        ) ]
      end.to_h
    end
  end
end
