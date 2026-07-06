require "administrate/base_dashboard"

class CatalogPinDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    catalog: Field::String,
    ref: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    catalog
    ref
    updated_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    catalog
    ref
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    catalog
    ref
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
