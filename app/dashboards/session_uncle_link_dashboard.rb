require "administrate/base_dashboard"

class SessionUncleLinkDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    uncle_session: Field::BelongsTo.with_options(class_name: "Session"),
    source: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    id
    session
    uncle_session
    source
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    session
    uncle_session
    source
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  #
  # Deliberately empty. An edge means "this session actually queued or
  # interrupted that one" — a fact about something that happened, written only
  # by Sessions::RecordUncleEdge, which is also where the acyclicity invariant
  # lives. Hand-authoring one through an admin form would assert an event that
  # never occurred and could construct the cycle the writer refuses to. The
  # Supervisor route offers index, show and destroy only.
  FORM_ATTRIBUTES = %i[].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {}.freeze
end
