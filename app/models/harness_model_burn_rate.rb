# frozen_string_literal: true

# What one harness + model combination costs per minute of session time.
#
# The spot gate has to answer a question no percentage can: "if I admit this
# session now, how much money will the fleet have spent by the time I look
# again?" That needs a rate, and the only honest source for one is what the same
# kind of work has cost recently. BurnRateCalculator computes these on a cron
# from the same ledger and the same TokenPricing rates the Costs tab uses, so
# there is one costing path rather than two that drift.
#
# `harness` is the agent root — the dimension the Costs tab already breaks spend
# down by — because that is what predicts a session's spend shape. A router turn
# and a merge-gate turn move very different money on the same model.
#
# == The rate is per minute of ELAPSED session time, not of wall clock
#
# A session's minutes are the span between its first and last API call in the
# sample window, so idle time inside a turn counts and time after the session
# went dormant does not. That is the right denominator for the scheduler, which
# multiplies this by "how long until I re-check" for sessions that are running
# right now.
class HarnessModelBurnRate < ApplicationRecord
  # How many of a combination's most recent sessions the rate is computed over.
  #
  # Named rather than inlined because it is the one number that decides how
  # quickly the rate reacts: small enough that a change in how a harness works
  # shows up within a day, large enough that one runaway session does not become
  # the fleet's burn rate.
  SAMPLE_SESSIONS = 25

  # How far back the sampler looks for those sessions. A combination with
  # nothing in this horizon has no current rate — a harness retired a month ago
  # must not go on informing today's scheduling.
  SAMPLE_LOOKBACK = 30.days

  # The floor on one session's contribution to the denominator. A session with a
  # single API call spans zero seconds, and dividing its cost by zero would hand
  # the scheduler an infinite burn rate. One minute is the smallest interval the
  # gate reasons in anyway.
  MIN_SESSION_MINUTES = 1.0

  # A rate is stale once the cron has not refreshed it for this long — the point
  # at which the scheduler stops trusting it and falls back to the fleet
  # default. The recompute job runs far more often than this; the constant is
  # what makes a job that has silently stopped visible as a degradation rather
  # than as confidently wrong arithmetic.
  FRESHNESS_HORIZON = 6.hours

  validates :harness, :model, presence: true
  validates :harness, uniqueness: { scope: :model }
  validates :usd_per_minute, numericality: { greater_than_or_equal_to: 0 }

  scope :fresh, -> { where(computed_at: FRESHNESS_HORIZON.ago..) }
  scope :by_rate, -> { order(usd_per_minute: :desc) }

  class << self
    # Every current rate, keyed by [harness, model], in one query. The gate
    # needs a rate per running session and would otherwise do a lookup per
    # session on the scheduling hot path.
    #
    # @return [Hash{[String, String] => Float}]
    def table
      fresh.pluck(:harness, :model, :usd_per_minute)
        .to_h { |harness, model, rate| [ [ harness.to_s, model.to_s ], rate.to_f ] }
    end

    # The rate to assume for a session whose own combination has never been
    # sampled — a brand new agent root, a model rolled out this morning, or a
    # deployment where the cron has not run yet.
    #
    # Cost-weighted, not a plain mean: the fleet default should look like the
    # work the fleet actually does, and a plain mean would let a dozen tiny,
    # rarely-used combinations outvote the two roots that spend the money.
    #
    # nil when nothing has been sampled at all. That is a real state — a fresh
    # install — and the caller has to decide what to do about it rather than be
    # handed a fabricated number.
    #
    # @return [Float, nil]
    def fleet_default_usd_per_minute
      cost, minutes = fresh.pick(
        Arel.sql("COALESCE(SUM(sample_cost_usd), 0)"),
        Arel.sql("COALESCE(SUM(sample_minutes), 0)")
      )
      return nil if minutes.to_f <= 0

      cost.to_f / minutes.to_f
    end
  end

  # True when the cron has refreshed this row recently enough to decide on.
  def fresh? = computed_at.present? && computed_at >= FRESHNESS_HORIZON.ago

  def usd_per_hour = usd_per_minute * 60
end
