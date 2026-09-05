require "administrate/base_dashboard"

class CategoryDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String,
    description: Field::Text,
    position: Field::Number,
    is_frozen: Field::Boolean,
    sessions: Field::HasMany,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    name
    position
    updated_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[
    name
    description
    position
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
