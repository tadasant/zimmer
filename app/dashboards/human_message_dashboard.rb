require "administrate/base_dashboard"

class HumanMessageDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
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
  # Deliberately empty. HumanMessage is read-only once recorded — it raises
  # ActiveRecord::ReadOnlyRecord on update — and hand-authoring one through an
  # admin form would forge a human author, which is the exact failure this whole
  # feature exists to prevent. The Supervisor route offers index, show and
  # destroy only.
  FORM_ATTRIBUTES = %i[].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {
    slack: ->(resources) { resources.where(channel: HumanMessage::SLACK) },
    web: ->(resources) { resources.where(channel: HumanMessage::WEB_UI) }
  }.freeze
end
