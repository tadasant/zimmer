require "administrate/base_dashboard"

class CategoryDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String,
    position: Field::Number,
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

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    name
    position
    sessions
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    name
    position
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
