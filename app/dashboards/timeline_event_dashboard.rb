require "administrate/base_dashboard"

class TimelineEventDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    event_type: Field::String,
    author: Field::String,
    channel: Field::String,
    content: Field::Text,
    occurred_at: Field::DateTime,
    provenance: Field::String.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    id
    session
    author
    occurred_at
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    session
    event_type
    author
    channel
    provenance
    content
    occurred_at
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  #
  # Deliberately empty. TimelineEvent is append-only — it raises
  # ActiveRecord::ReadOnlyRecord on update — and hand-authoring one through an
  # admin form would forge a human author, which is the exact failure the whole
  # feature exists to prevent. The Supervisor route offers index, show and
  # destroy only.
  FORM_ATTRIBUTES = %i[].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {
    live: ->(resources) { resources.where(event_type: TimelineEvent::HUMAN_MESSAGE) }
  }.freeze
end
