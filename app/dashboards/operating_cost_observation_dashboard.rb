# frozen_string_literal: true

require "administrate/base_dashboard"

# Raw money facts as reported — daily costs, period-to-date totals, invoices.
# Read-only: every write goes through the Costs page, the REST API or
# `action_operating_costs` (OperatingCosts::Actions), so the daily series and
# allocations are rebuilt after it.
class OperatingCostObservationDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account: Field::BelongsTo,
    metric: Field::String,
    as_of_date: Field::Date,
    period_start: Field::Date,
    period_end: Field::Date,
    amount: Field::Number.with_options(decimals: 4),
    currency: Field::String,
    amount_usd: Field::Number.with_options(decimals: 4),
    source: Field::String,
    confidence: Field::String,
    collector: Field::String,
    raw_payload: Field::String.with_options(searchable: false),
    evidence: Field::Text,
    recorded_by_session_id: Field::Number,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id account metric as_of_date amount_usd source confidence].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
