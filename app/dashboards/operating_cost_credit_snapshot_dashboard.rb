# frozen_string_literal: true

require "administrate/base_dashboard"

# Credit balances over time; burn and run-out are computed from these.
# Read-only: every write goes through the Costs page, the REST API or
# `action_operating_costs` (OperatingCosts::Actions), so the daily series and
# allocations are rebuilt after it.
class OperatingCostCreditSnapshotDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account: Field::BelongsTo,
    as_of_date: Field::Date,
    balance: Field::Number.with_options(decimals: 4),
    currency: Field::String,
    balance_usd: Field::Number.with_options(decimals: 4),
    kind: Field::String,
    granted_total: Field::Number.with_options(decimals: 4),
    expires_on: Field::Date,
    source: Field::String,
    evidence: Field::Text,
    recorded_by_session_id: Field::Number,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id account as_of_date balance_usd kind source].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
