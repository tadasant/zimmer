require "administrate/base_dashboard"

class TriggerConditionDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    trigger: Field::BelongsTo,
    condition_type: Field::String,
    configuration: Field::String.with_options(searchable: false),
    last_polled_at: Field::DateTime,
    last_triggered_at: Field::DateTime,
    last_message_ts: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    trigger
    condition_type
    last_triggered_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    trigger
    condition_type
    configuration
    last_polled_at
    last_triggered_at
    last_message_ts
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    trigger
    condition_type
    configuration
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
