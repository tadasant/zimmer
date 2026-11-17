# frozen_string_literal: true

module OperatingCosts
  # Rebuilds one account's canonical daily series from its raw facts.
  #
  # A pure function of the observations and subscriptions: the same inputs
  # always produce the same rows, so a rebuild is safe to run as often as
  # anything likes. For each day the highest-precedence fact wins:
  #
  #   1. an `invoice` covering the day, spread evenly over its period (billed)
  #   2. a `daily_cost`, or the day-over-day difference of a `period_to_date`,
  #      from anything but `derived` (metered)
  #   3. a `derived` estimate from Zimmer's own ledgers (estimated)
  #   4. active subscriptions, prorated (monthly × 12 ÷ 365, yearly ÷ 365)
  #
  # A subscription that includes usage (`included_usage_usd`) is the exception to
  # "the highest wins": its fee is always charged, and usage on top of it counts
  # only once the month's cumulative usage passes what the plan includes.
  #
  # Within one rank, a fact from a more trusted source wins (billing_api, then
  # card_statement, agent, manual). Every amount is multiplied by the account's
  # `zimmer_share`.
  class Ledger
    SOURCE_TRUST = %w[billing_api card_statement agent manual derived].freeze

    def self.rebuild!(account:, from:, to:)
      new(account).rebuild!(from.to_date, to.to_date)
    end

    def initialize(account)
      @account = account
    end

    # @return [Integer] the number of daily rows written
    def rebuild!(from, to)
      return 0 if to < from

      share = @account.zimmer_share.to_d
      rows = (from..to).filter_map do |date|
        entry = entry_for(date)
        next unless entry

        { account_id: @account.id, date: date, amount_usd: (entry[:amount] * share).round(4), basis: entry[:basis],
          confidence: entry[:confidence], source: entry[:source], created_at: Time.current, updated_at: Time.current }
      end

      OperatingCostDailyEntry.transaction do
        @account.daily_entries.where(date: from..to).delete_all
        OperatingCostDailyEntry.insert_all!(rows) if rows.any?
      end
      rows.size
    end

    private

    def observations
      @observations ||= @account.observations.to_a
    end

    # Observations indexed by the day they speak for, so a 400-day rebuild does
    # not rescan every observation for every day.
    def observations_on(date)
      @by_date ||= observations.group_by(&:as_of_date)
      @by_date.fetch(date, [])
    end

    def subscriptions
      @subscriptions ||= @account.subscriptions.to_a
    end

    def entry_for(date)
      included = subscriptions.select { |s| s.active_on?(date) && s.included_usage_usd.to_d.positive? }
      invoice = invoice_entry(date)
      return invoice if invoice

      usage = usage_entry(date)
      if included.any?
        # Every active subscription's fee — an extra seat beside the plan too —
        # plus the usage past what the plan includes.
        fee = subscriptions.select { |s| s.active_on?(date) }.sum(&:daily_usd)
        overage = usage ? overage_on(date, included) : 0.to_d
        return { amount: fee + overage, basis: "prorated_subscription", confidence: usage ? usage[:confidence] : "estimated",
                 source: usage ? usage[:source] : "subscription" }
      end
      return usage if usage

      subscription_entry(date)
    end

    def invoice_entry(date)
      @invoices ||= observations.select { |o| o.metric == "invoice" }
      invoice = pick(@invoices.select { |o| o.period_start <= date && o.period_end >= date })
      return unless invoice

      days = (invoice.period_end - invoice.period_start).to_i + 1
      { amount: invoice.amount_usd.to_d / days, basis: "prorated_invoice", confidence: "billed", source: invoice.source }
    end

    # Rank 2 then rank 3: an external usage figure, then Zimmer's own estimate.
    def usage_entry(date)
      @usage_entries ||= {}
      return @usage_entries[date] if @usage_entries.key?(date)

      @usage_entries[date] = usage_on(date, external: true) || usage_on(date, external: false)
    end

    def usage_on(date, external:)
      candidates = observations_on(date).reject { |o| (o.source == "derived") == external }
      daily = pick(candidates.select { |o| o.metric == "daily_cost" })
      if daily
        return { amount: daily.amount_usd.to_d, basis: "observed", confidence: daily.confidence, source: daily.source }
      end

      differenced(candidates, date, external)
    end

    def running_totals
      @running_totals ||= observations.select { |o| o.metric == "period_to_date" }
    end

    # A running total: the day's cost is today's figure minus the latest earlier
    # figure in the same period. Days the total was not reported on carry
    # nothing, and the next report carries everything accrued since, so a missed
    # day moves money rather than losing it. The first report of a period counts
    # everything the period accrued before it.
    def differenced(candidates, date, external)
      today = pick(candidates.select { |o| o.metric == "period_to_date" })
      return unless today

      earlier = running_totals.select do |o|
        o.period_start == today.period_start && o.as_of_date < date && (o.source == "derived") != external
      end
      previous_date = earlier.map(&:as_of_date).max
      previous = previous_date && pick(earlier.select { |o| o.as_of_date == previous_date })

      amount = today.amount_usd.to_d - (previous&.amount_usd.to_d || 0)
      { amount: [ amount, 0 ].max, basis: "differenced", confidence: today.confidence, source: today.source }
    end

    # The part of this day's usage above what the active plan includes for its
    # calendar month.
    def overage_on(date, included)
      allowance = included.sum { |s| s.included_usage_usd.to_d * s.quantity }
      before = (date.beginning_of_month...date).sum { |d| usage_entry(d)&.dig(:amount) || 0 }
      today = usage_entry(date)&.dig(:amount) || 0
      [ before + today - allowance, 0 ].max - [ before - allowance, 0 ].max
    end

    def subscription_entry(date)
      active = subscriptions.select { |s| s.active_on?(date) }
      return if active.empty?

      { amount: active.sum(&:daily_usd), basis: "prorated_subscription", confidence: "estimated", source: "subscription" }
    end

    def pick(candidates)
      candidates.min_by { |o| [ SOURCE_TRUST.index(o.source) || SOURCE_TRUST.size, -o.updated_at.to_f ] }
    end
  end
end
