# frozen_string_literal: true

require "administrate/base_dashboard"

# Billable things (a seat, a server, a credit pool) behind the Costs page.
# Read-only: every write goes through the Costs page, the REST API or
# `action_operating_costs` (OperatingCosts::Actions), so the daily series and
# allocations are rebuilt after it.
class OperatingCostAccountDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    vendor: Field::BelongsTo,
    functionality: Field::BelongsTo,
    key: Field::String,
    label: Field::String,
    paid_by: Field::String,
    zimmer_share: Field::Number.with_options(decimals: 4),
    allocation_rule: Field::String,
    allocation_config: Field::String.with_options(searchable: false),
    derived_source: Field::String,
    environment: Field::String,
    external_ref: Field::String,
    notes: Field::Text,
    active: Field::Boolean,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id key label vendor functionality paid_by allocation_rule active].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(resource) = resource.key
end
