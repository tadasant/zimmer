# frozen_string_literal: true

# Turns Anthropic's quota percentages into dollars, and writes the result to
# QuotaCapacityEstimate.
#
# == What it does
#
# For each window, divide what the deployment spent over that window's length by
# the pool's average utilization of it. The numerator is Opus-denominated: every
# stored token volume re-priced at the Opus rate, so the answer is "$X of Opus
# spend", which is the unit the request asked for and the only one that means
# anything here — over 99% of this fleet's spend is Opus already.
#
# The numerator is TOTAL spend across the pool and the denominator is the MEAN
# utilization across it, which is what makes the ratio the pool's whole capacity
# rather than one account's. With N accounts of capacity C, spend is
# `sum(C * u_i) = C * N * mean(u)`, so `spend / mean(u) = N * C`.
#
# == Why it is only ever an estimate
#
# Three approximations, none of them hideable:
#
#   * Zimmer's ledger is list-price spend from transcripts; Anthropic's quota
#     counter is its own accounting of the same calls, and the two are not the
#     same function of tokens.
#   * "The last 5 hours of spend" is not exactly "the spend inside each
#     account's own 5-hour window" — the windows reset at different moments per
#     account.
#   * Spend Zimmer never saw (a transcript it could not read) is missing from
#     the numerator and present in Anthropic's counter.
#
# So the figure is smoothed rather than trusted point-to-point, every surface
# that renders it labels it an estimate, and the gate degrades to reasoning in
# percentages when there is no usable estimate at all rather than pretending.
class QuotaCapacityCalibrator
  # Ledger tables that count against a Claude quota window. Codex spend does not
  # touch these windows and has no table here.
  QUOTA_BEARING_TABLES = [ SessionTokenUsage, AdhocTokenUsage ].freeze

  Observation = Data.define(:window_key, :cost_usd, :utilization, :capacity_usd, :usable, :reason) do
    def usable? = usable
  end

  class << self
    # Recompute both windows and persist what is usable.
    #
    # @return [Array<Observation>] every window's observation, usable or not, so
    #   the job can log why a window was skipped rather than silently no-op.
    def calibrate!(now: Time.current)
      measure = ClaudeAccountPool.measure
      stored = QuotaCapacityEstimate.table

      QuotaCapacityEstimate::WINDOW_KEYS.map do |window_key|
        observation = observe(window_key, measure, now: now)
        next observation unless observation.usable?

        record = stored[window_key] || QuotaCapacityEstimate.new(window_key: window_key)
        record.absorb(
          observed: observation.capacity_usd,
          sample_cost_usd: observation.cost_usd,
          sample_utilization: observation.utilization
        ).save!

        observation
      end
    end

    # This run's ratio for one window, and whether it is worth absorbing.
    #
    # @param measure [ClaudeAccountPool::Measure]
    # @return [Observation]
    def observe(window_key, measure, now: Time.current)
      utilization = window_key == QuotaCapacityEstimate::WEEKLY ? measure.weekly : measure.five_hour
      seconds = QuotaCapacityEstimate.window_seconds(window_key)

      if utilization.nil?
        return unusable(window_key, nil, nil, "no pooled utilization reading")
      end
      if utilization < QuotaCapacityEstimate::MIN_SAMPLE_UTILIZATION
        return unusable(window_key, nil, utilization,
                        "pool utilization #{(utilization * 100).round(2)}% is too small a denominator")
      end

      cost = opus_denominated_spend(now - seconds, now)
      if cost < QuotaCapacityEstimate::MIN_SAMPLE_COST_USD
        return unusable(window_key, cost, utilization, "only $#{cost.round(2)} of spend in the window")
      end

      Observation.new(
        window_key: window_key, cost_usd: cost, utilization: utilization,
        capacity_usd: cost / utilization, usable: true, reason: nil
      )
    end

    # What everything in `[from, to]` would have cost had it all run on Opus.
    #
    # Both ledger tables, because both spend against the same quota windows: an
    # agent session's calls and the ad hoc ones Zimmer's own code makes (session
    # titles, the CLI status probe) come out of the same allowance.
    #
    # @return [Float]
    def opus_denominated_spend(from, to)
      QUOTA_BEARING_TABLES.sum do |klass|
        klass
          .in_window(from, to)
          .pick(Arel.sql("COALESCE(SUM(#{TokenPricing.cost_sql(klass.table_name, as_family: TokenPricing::QUOTA_DENOMINATION_FAMILY)}), 0)"))
          .to_f
      end
    end

    private

    def unusable(window_key, cost, utilization, reason)
      Observation.new(window_key: window_key, cost_usd: cost, utilization: utilization,
                      capacity_usd: nil, usable: false, reason: reason)
    end
  end
end
