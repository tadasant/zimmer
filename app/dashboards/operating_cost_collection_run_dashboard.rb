# frozen_string_literal: true

require "administrate/base_dashboard"

# Has operating-cost collection run, and what did it cover.
# Read-only: every write goes through the Costs page, the REST API or
# `action_operating_costs` (OperatingCosts::Actions), so the daily series and
# allocations are rebuilt after it.
class OperatingCostCollectionRunDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    collector: Field::String,
    status: Field::String,
    started_at: Field::DateTime,
    finished_at: Field::DateTime,
    rows_written: Field::Number,
    error: Field::Text,
    session_id: Field::Number,
    details: Field::String.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id collector status started_at rows_written].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
