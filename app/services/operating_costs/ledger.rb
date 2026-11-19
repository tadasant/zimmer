# frozen_string_literal: true

module OperatingCosts
  # Rebuilds one account's canonical daily series from its raw facts.
  #
  # A pure function of the observations and subscriptions: the same inputs
  # always produce the same rows, so a rebuild is safe to run as often as
  # anything likes. For each day the highest-precedence fact wins:
  #
  #   1. an `invoice` covering the day, spread evenly over its period (billed)
  #   2. a `daily_cost`, or a `period_to_date` running total's increase spread
  #      evenly over the days it accrued on, from anything but `derived` (metered)
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

      spread_running_totals(external)[date]
    end

    # A running total, turned into days. Each report's increase over the
    # previous report in the same period is spread evenly over the days since
    # that report; the first report of a period spreads over the period up to
    # it. So a collector that catches up after missing days, or a vendor whose
    # figure lags, puts each day's share on that day instead of piling the whole
    # gap onto the day the figure arrived. The period's days always sum to its
    # latest total: a total that goes down (a credit or a correction) spreads its
    # drop over the same days as negative amounts rather than being dropped.
    # Days after the latest report carry nothing until the next one arrives.
    #
    # @return [Hash{Date => Hash}] the day's entry, keyed by date
    def spread_running_totals(external)
      @spread ||= {}
      @spread[external] ||= begin
        by_day = {}
        readings = observations.select { |o| o.metric == "period_to_date" && (o.source == "derived") != external }
        readings.group_by(&:period_start).each do |period_start, in_period|
          covered_through = nil
          previous_amount = 0.to_d
          in_period.group_by(&:as_of_date).sort.each do |as_of, same_day|
            reading = pick(same_day)
            last_day = [ as_of, reading.period_end ].compact.min
            first_day = covered_through ? covered_through + 1 : period_start
            first_day = [ first_day, last_day ].min
            spread_over(by_day, first_day..last_day, reading.amount_usd.to_d - previous_amount, reading)
            covered_through = [ covered_through, last_day ].compact.max
            previous_amount = reading.amount_usd.to_d
          end
        end
        by_day
      end
    end

    # Equal shares to four places, the rounding remainder on the last day, so the
    # days add up to the delta exactly.
    def spread_over(by_day, days, delta, reading)
      count = days.count
      share = (delta / count).round(4)
      days.each_with_index do |day, i|
        amount = i == count - 1 ? delta - share * (count - 1) : share
        prior = by_day[day]&.dig(:amount) || 0
        by_day[day] = { amount: prior + amount, basis: "differenced", confidence: reading.confidence, source: reading.source }
      end
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
