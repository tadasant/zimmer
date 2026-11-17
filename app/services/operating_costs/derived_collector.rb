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
  # An account with no `derived_source` gets nothing, and so does a deployment
  # that has not created one: the repository ships no vendor names. A real bill
  # recorded later on the same account outranks these (OperatingCosts::Ledger).
  #
  # Days are the app time zone's calendar days, not UTC's.
  class DerivedCollector
    WINDOW_DAYS = 35

    def initialize(today: Date.current)
      @to = today - 1
      @from = @to - WINDOW_DAYS + 1
    end

    # @return [Array<Hash>] observation items in the Recorder's payload shape
    def observations
      OperatingCostAccount.where(derived_source: OperatingCostAccount::DERIVED_SOURCES).flat_map do |account|
        daily = case account.derived_source
        when "live_voice_metered" then live_voice_by_day
        when "pi_token_spend" then pi_spend_by_day
        else {}
        end
        daily.map do |date, amount|
          { "account" => account.key, "metric" => "daily_cost", "as_of_date" => date.iso8601, "amount" => amount.to_d.round(4),
            "currency" => "USD", "source" => "derived", "confidence" => "estimated",
            "evidence" => "Derived from Zimmer's #{account.derived_source.tr('_', ' ')} ledger at list price" }
        end
      end
    end

    private

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
        .transform_keys(&:to_date)
    end

    def pi_spend_by_day
      relation = SessionTokenUsage.where(called_at: window, agent_runtime: "pi")
      CostRollup.new(relation, local_day("session_token_usages.called_at"))
        .fold { |day, _model| day.to_date }
        .transform_values { |totals| totals[:cost_usd] }
    end
  end
end
