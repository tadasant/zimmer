# frozen_string_literal: true

module OperatingCosts
  # Row-level export of every operating-cost table, one kind at a time, newest
  # first. Behind `search_operating_cost_records` and
  # `GET /api/v1/operating_costs/records`.
  class Records
    PER_PAGE = 25
    MAX_PER_PAGE = 100
    KINDS = {
      "observations" => [ OperatingCostObservation, :as_of_date ],
      "credit_snapshots" => [ OperatingCostCreditSnapshot, :as_of_date ],
      "subscriptions" => [ OperatingCostSubscription, :started_on ],
      "daily_entries" => [ OperatingCostDailyEntry, :date ],
      "allocations" => [ OperatingCostMonthlyAllocation, :month ],
      "accounts" => [ OperatingCostAccount, nil ],
      "vendors" => [ OperatingCostVendor, nil ],
      "functionalities" => [ OperatingCostFunctionality, nil ],
      "runs" => [ OperatingCostCollectionRun, :started_at ]
    }.freeze

    # @raise [ArgumentError] on an unknown kind, account or date
    def self.search(kind:, account: nil, from: nil, to: nil, page: nil, per_page: nil)
      model, date_column = KINDS.fetch(kind.to_s) { raise ArgumentError, "kind must be one of #{KINDS.keys.join(', ')}" }
      page = [ page.to_i, 1 ].max
      per_page = (per_page.presence || PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)

      scope = model.all
      if account.present?
        raise ArgumentError, "account does not apply to #{kind}" unless model.column_names.include?("account_id")

        record = OperatingCostAccount.find_by(key: account) || raise(ArgumentError, "Unknown account: #{account}")
        scope = scope.where(account_id: record.id)
      end
      if date_column
        scope = scope.where(date_column => parse(from)..) if from.present?
        scope = scope.where(date_column => ..parse(to)) if to.present?
        scope = scope.order(date_column => :desc, id: :desc)
      else
        scope = scope.order(:key)
      end
      scope = scope.includes(:account) if model.reflect_on_association(:account)
      scope = scope.includes(:vendor, :functionality) if model == OperatingCostAccount
      scope = scope.includes(:functionality) if model == OperatingCostMonthlyAllocation

      total = scope.count
      rows = scope.offset((page - 1) * per_page).limit(per_page).map(&:as_api_json)
      { kind: kind.to_s, page: page, per_page: per_page, total: total, has_more: page * per_page < total, records: rows }
    end

    def self.parse(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      raise ArgumentError, "#{value.inspect} is not a YYYY-MM-DD date"
    end
  end
end
