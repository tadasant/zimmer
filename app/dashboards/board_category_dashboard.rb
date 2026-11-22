require "administrate/base_dashboard"

# Your board v2's categories. Presentation state only (name, order, collapse,
# category-level visibility); nothing here is read by scheduling.
class BoardCategoryDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String,
    position: Field::Number,
    collapsed: Field::Boolean,
    visibility: Field::String,
    snoozed_until: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    name
    position
    visibility
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    name
    position
    collapsed
    visibility
    snoozed_until
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    name
    position
    collapsed
    visibility
    snoozed_until
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
