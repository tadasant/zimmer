# frozen_string_literal: true

require "administrate/base_dashboard"

# Each account-month split by agent root and functionality (OperatingCosts::Allocator). Derived.
# Read-only: every write goes through the Costs page, the REST API or
# `action_operating_costs` (OperatingCosts::Actions), so the daily series and
# allocations are rebuilt after it.
class OperatingCostMonthlyAllocationDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account: Field::BelongsTo,
    functionality: Field::BelongsTo,
    month: Field::Date,
    agent_root: Field::String,
    amount_usd: Field::Number.with_options(decimals: 4),
    share: Field::Number.with_options(decimals: 4),
    allocation_method: Field::String,
    basis_detail: Field::String.with_options(searchable: false),
    computed_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id account month agent_root functionality amount_usd allocation_method].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
