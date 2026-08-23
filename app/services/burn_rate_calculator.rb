# frozen_string_literal: true

# Computes the "$ per minute" of every harness + model combination from the
# ledger, and writes it to HarnessModelBurnRate.
#
# The costing path is the Costs tab's, not a second one: the dollars come from
# `SessionTokenUsage.cost_sum_sql`, which is `TokenPricing.cost_sql` — the same
# expression CostAnalytics groups by agent root and model. A rate that priced
# tokens differently from the Costs page would make "this session burns $0.40 a
# minute" and "this root spent $6,116 this week" two numbers nobody could
# reconcile.
#
# == The sample
#
# The last HarnessModelBurnRate::SAMPLE_SESSIONS sessions of each combination,
# newest first, within SAMPLE_LOOKBACK. Per session the calculator takes what it
# cost and how long it was running — the span from its first API call on that
# combination to its last — and the rate is the sum of the costs over the sum of
# the spans. Summing before dividing rather than averaging per-session rates is
# deliberate: a session that made two calls a second apart would otherwise
# contribute a wild per-minute figure with the same weight as a two-hour one.
#
# == One query, then Ruby
#
# The GROUP BY is over (agent_root, model, session_id) inside the lookback,
# which is thousands of rows on this deployment — not the millions the raw
# ledger holds. Taking "the newest 25 per combination" in SQL would need a
# window function and a subquery; doing it in Ruby over a few thousand tuples
# costs nothing and stays readable.
class BurnRateCalculator
  Sample = Data.define(:harness, :model, :cost_usd, :minutes, :sessions, :newest_at, :oldest_at) do
    # Zero minutes cannot happen — every session contributes at least
    # MIN_SESSION_MINUTES — but a rate is money and dividing by zero is not a
    # thing to leave to chance on the scheduling path.
    def usd_per_minute = minutes.positive? ? cost_usd / minutes : 0.0
  end

  class << self
    # Recompute every combination and persist the results.
    #
    # Combinations that fall out of the lookback are DELETED rather than left at
    # their last value: a rate nothing refreshes is a rate the scheduler would go
    # on trusting for a harness that no longer exists. `fresh` would hide them
    # anyway, and dropping the row keeps the table a statement about what is
    # running now. A run that samples NOTHING deletes nothing — see below.
    #
    # @return [Integer] how many combinations have a current rate
    def recompute_all
      samples = compute_samples
      now = Time.current

      # An empty sample is "the ledger had nothing to say this run", not "no
      # combination has a rate any more". Wiping on it would drop every rate on
      # one bad pass — an ingestion hiccup, a lookback edge — and silently drop
      # the whole fleet out of dollar mode until the next good one.
      return 0 if samples.empty?

      HarnessModelBurnRate.upsert_all(
        samples.map do |sample|
          {
            harness: sample.harness, model: sample.model,
            usd_per_minute: sample.usd_per_minute,
            sample_cost_usd: sample.cost_usd, sample_minutes: sample.minutes,
            sample_session_count: sample.sessions,
            sample_newest_at: sample.newest_at, sample_oldest_at: sample.oldest_at,
            computed_at: now, created_at: now, updated_at: now
          }
        end,
        unique_by: %i[harness model]
      )

      # Everything this run wrote carries `now`, so anything older is a
      # combination the lookback no longer contains. One indexed comparison,
      # rather than an OR chain naming every surviving key.
      HarnessModelBurnRate.where(computed_at: ...now).delete_all

      samples.size
    end

    # The rates as they would be written, without writing them. The job calls
    # `recompute_all`; this is what a test or a console reads to see the working.
    #
    # @return [Array<Sample>]
    def compute_samples(now: Time.current)
      rows = session_spans(now)
      return [] if rows.empty?

      rows.group_by { |row| [ row[:harness], row[:model] ] }.filter_map do |(harness, model), sessions|
        sampled = sessions.sort_by { |s| -s[:last_at].to_i }.first(HarnessModelBurnRate::SAMPLE_SESSIONS)
        minutes = sampled.sum { |s| session_minutes(s) }
        next if minutes <= 0

        Sample.new(
          harness: harness, model: model,
          cost_usd: sampled.sum { |s| s[:cost_usd] },
          minutes: minutes,
          sessions: sampled.size,
          newest_at: sampled.filter_map { |s| s[:last_at] }.max,
          oldest_at: sampled.filter_map { |s| s[:first_at] }.min
        )
      end
    end

    private

    # One row per (agent_root, model, session) in the lookback: what it cost and
    # the span it spent doing so.
    #
    # Rows with no `session_id` are excluded — spend the transcript-to-session
    # join could not attribute has no session to be a rate PER. Rows with no
    # `agent_root` are excluded for the same reason on the other axis.
    def session_spans(now)
      since = now - HarnessModelBurnRate::SAMPLE_LOOKBACK

      SessionTokenUsage
        .in_window(since, now)
        .where.not(session_id: nil)
        .where.not(agent_root: [ nil, "" ])
        .group(:agent_root, :model, :session_id)
        .pluck(
          :agent_root, :model, :session_id,
          SessionTokenUsage.cost_sum_sql,
          Arel.sql("MIN(called_at)"), Arel.sql("MAX(called_at)")
        )
        .map do |harness, model, session_id, cost, first_at, last_at|
          {
            harness: harness.to_s, model: model.to_s, session_id: session_id,
            cost_usd: cost.to_f, first_at: first_at, last_at: last_at
          }
        end
    end

    # How long one session was running on this combination, floored so a
    # single-call session cannot divide by zero. See
    # HarnessModelBurnRate::MIN_SESSION_MINUTES.
    def session_minutes(span)
      return HarnessModelBurnRate::MIN_SESSION_MINUTES if span[:first_at].nil? || span[:last_at].nil?

      seconds = span[:last_at] - span[:first_at]
      [ seconds / 60.0, HarnessModelBurnRate::MIN_SESSION_MINUTES ].max
    end
  end
end
