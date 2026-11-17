# frozen_string_literal: true

require "administrate/base_dashboard"

# Fixed, effective-dated charges, prorated daily by OperatingCosts::Ledger.
# Read-only: every write goes through the Costs page, the REST API or
# `action_operating_costs` (OperatingCosts::Actions), so the daily series and
# allocations are rebuilt after it.
class OperatingCostSubscriptionDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account: Field::BelongsTo,
    plan_name: Field::String,
    amount: Field::Number.with_options(decimals: 4),
    currency: Field::String,
    amount_usd: Field::Number.with_options(decimals: 4),
    interval: Field::String,
    quantity: Field::Number,
    included_usage_usd: Field::Number.with_options(decimals: 4),
    started_on: Field::Date,
    ended_on: Field::Date,
    renews_on: Field::Date,
    auto_renew: Field::Boolean,
    notes: Field::Text,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id account plan_name amount_usd interval quantity started_on ended_on].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
