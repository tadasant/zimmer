require "administrate/base_dashboard"

class AppSettingDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    default_runtime: Field::String,
    default_model: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    default_runtime
    default_model
    updated_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    default_runtime
    default_model
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    default_runtime
    default_model
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
