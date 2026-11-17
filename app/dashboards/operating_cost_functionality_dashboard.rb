# frozen_string_literal: true

require "administrate/base_dashboard"

# The capability taxonomy the Costs page breaks costs down by.
# Read-only: every write goes through the Costs page, the REST API or
# `action_operating_costs` (OperatingCosts::Actions), so the daily series and
# allocations are rebuilt after it.
class OperatingCostFunctionalityDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    key: Field::String,
    name: Field::String,
    description: Field::Text,
    agent_roots: Field::String.with_options(searchable: false),
    mcp_servers: Field::String.with_options(searchable: false),
    position: Field::Number,
    active: Field::Boolean,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id key name position active].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(resource) = resource.key
end
