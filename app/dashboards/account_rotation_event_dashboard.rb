require "administrate/base_dashboard"

class AccountRotationEventDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    rotated_from: Field::BelongsTo.with_options(class_name: "ClaudeAccount"),
    rotated_to: Field::BelongsTo.with_options(class_name: "ClaudeAccount"),
    reason: Field::String,
    source: Field::String,
    triggered_by: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    rotated_from
    rotated_to
    reason
    source
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    rotated_from
    rotated_to
    reason
    source
    triggered_by
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
