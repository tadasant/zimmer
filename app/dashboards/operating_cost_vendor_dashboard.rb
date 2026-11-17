# frozen_string_literal: true

require "administrate/base_dashboard"

# Vendors behind the Costs page.
# Read-only: every write goes through the Costs page, the REST API or
# `action_operating_costs` (OperatingCosts::Actions), so the daily series and
# allocations are rebuilt after it.
class OperatingCostVendorDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    key: Field::String,
    name: Field::String,
    category: Field::String,
    pricing_model: Field::String,
    ingest_method: Field::String,
    billing_url: Field::String,
    notes: Field::Text,
    active: Field::Boolean,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id key name category pricing_model ingest_method active].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(resource) = resource.key
end
