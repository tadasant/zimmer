# frozen_string_literal: true

module OperatingCosts
  # The costs Zimmer can see in its own ledgers, with no secret and no vendor
  # call: written as `derived`, `estimated` daily observations on whichever
  # account carries the matching `derived_source`.
  #
  # - `live_voice_metered`: Live Mode's metered voice spend (LiveUsageEvent rows
  #   whose `billing_basis` is metered — the OpenAI side; Claude delegations are
  #   subscription-billed and are not money). A price-table estimate.
  # - `pi_token_spend`: the Pi runtime's token ledger at list price. Pi is the
  #   one runtime whose token dollars are real metered money; Claude Code and
  #   Codex token dollars are list price against a subscription and are never
  #   counted here.
  #
  # Unpriced usage is never a figure. A Pi call on a model TokenPricing has no
  # rate for is money owed at an unknown amount, so a day whose only Pi usage
  # is unpriced gets NO observation rather than a $0 that reads as "nothing
  # owed", and a day with some priced usage records the priced part as a floor
  # and says what it left out. OperatingCosts::Report turns both into
  # `stale_reasons`, from the same window this reads (#gaps).
  #
  # The window is the job's to own: a derived observation in it for a day this
  # does not derive (a $0 for a day whose usage is unpriced) is #superseded and
  # removed, so a wrong figure cannot outlive the reason it was wrong.
  #
  # An account with no `derived_source` gets nothing, and so does a deployment
  # that has not created one: the repository ships no vendor names. A real bill
  # recorded later on the same account outranks these (OperatingCosts::Ledger).
  #
  # Days are the app time zone's calendar days, not UTC's.
  class DerivedCollector
    WINDOW_DAYS = 35

    attr_reader :from, :to

    def initialize(today: Date.current)
      @to = today - 1
      @from = @to - WINDOW_DAYS + 1
    end

    # @return [Array<Hash>] observation items in the Recorder's payload shape
    def observations
      @observations ||= accounts.flat_map do |account|
        daily(account).map do |date, (amount, unpriced)|
          evidence = "Derived from Zimmer's #{account.derived_source.tr('_', ' ')} ledger at list price"
          if unpriced.any?
            evidence += ". A floor: excludes usage on #{unpriced.join(', ')}, which has no rate in TokenPricing"
          end
          { "account" => account.key, "metric" => "daily_cost", "as_of_date" => date.iso8601, "amount" => amount.to_d.round(4),
            "currency" => "USD", "source" => "derived", "confidence" => "estimated", "evidence" => evidence }
        end
      end
    end

    # Derived observations in the window for an (account, day) #observations no
    # longer produces.
    #
    # @return [ActiveRecord::Relation<OperatingCostObservation>]
    def superseded
      emitted = observations.map { |o| [ o["account"], o["as_of_date"] ] }.to_set
      keys = accounts.index_by(&:id)
      ids = OperatingCostObservation.where(account_id: keys.keys, source: "derived", metric: "daily_cost", as_of_date: @from..@to)
        .pluck(:id, :account_id, :as_of_date)
        .reject { |_, account_id, date| emitted.include?([ keys[account_id].key, date.iso8601 ]) }
        .map(&:first)
      OperatingCostObservation.where(id: ids)
    end

    # What each derived account's source did in the window, for freshness:
    # the last day that should have a figure, and the models it used that have
    # no rate (with the first day one was used).
    #
    # @return [Hash{OperatingCostAccount => Hash}] `{ last_due_on:, unpriced_models:, unpriced_since: }`
    def gaps
      @gaps ||= accounts.to_h do |account|
        unpriced = usage(account).select { |_, (_, models)| models.any? }
        [ account, { last_due_on: daily(account).keys.max, unpriced_models: unpriced.values.flat_map(&:last).uniq.sort,
                     unpriced_since: unpriced.keys.min } ]
      end
    end

    private

    def accounts
      @accounts ||= OperatingCostAccount.where(derived_source: OperatingCostAccount::DERIVED_SOURCES).includes(:vendor).to_a
    end

    # Days that get a figure: those with something priced.
    def daily(account)
      usage(account).select { |_, (amount, unpriced)| amount.positive? || unpriced.empty? }
    end

    # @return [Hash{Date => [BigDecimal, Array<String>]}] each day with usage:
    #   the priced amount and the unpriced models
    def usage(account)
      (@usage ||= {})[account.derived_source] ||= case account.derived_source
      when "live_voice_metered" then live_voice_by_day
      when "pi_token_spend" then pi_spend_by_day
      else {}
      end
    end

    def window
      Time.zone.local(@from.year, @from.month, @from.day)...Time.zone.local(@to.year, @to.month, @to.day).tomorrow
    end

    def local_day(column)
      zone = ActiveRecord::Base.connection.quote(Time.zone.tzinfo.name)
      "DATE((#{column} AT TIME ZONE 'UTC') AT TIME ZONE #{zone})"
    end

    def live_voice_by_day
      LiveUsageEvent.where(occurred_at: window, billing_basis: "metered")
        .group(Arel.sql(local_day("live_usage_events.occurred_at")))
        .sum(:cost_usd)
        .to_h { |day, amount| [ day.to_date, [ amount.to_d, [] ] ] }
    end

    def pi_spend_by_day
      relation = SessionTokenUsage.where(called_at: window, agent_runtime: "pi")
      CostRollup.new(relation, local_day("session_token_usages.called_at")).rows
        .group_by { |row| row.keys.first.to_date }
        .transform_values do |rows|
          priced, unpriced = rows.partition { |row| TokenPricing.priced?(row.model) }
          [ priced.sum(0.to_d) { |row| row.cost_usd.to_d }, unpriced.map(&:model).uniq.sort ]
        end
    end
  end
end
