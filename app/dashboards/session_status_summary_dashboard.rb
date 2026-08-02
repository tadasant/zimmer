require "administrate/base_dashboard"

class SessionStatusSummaryDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    fork_session: Field::BelongsTo.with_options(class_name: "Session"),
    summary: Field::Text,
    state: Field::String,
    error: Field::Text,
    generated_at: Field::DateTime,
    transcript_line_count: Field::Number,
    requested_at: Field::DateTime,
    requested_line_count: Field::Number,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    id
    session
    state
    generated_at
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    session
    state
    summary
    error
    generated_at
    transcript_line_count
    fork_session
    requested_at
    requested_line_count
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  #
  # `state` only. The text is agent-written and the two line counts are the
  # staleness arithmetic — hand-editing either would make the panel lie about
  # how current it is. What an operator does need is a way to clear a row wedged
  # in `pending` by a fork that died without ever reaching pause or fail.
  FORM_ATTRIBUTES = %i[
    state
  ].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {
    pending: ->(resources) { resources.where(state: "pending") },
    failed: ->(resources) { resources.where(state: "failed") }
  }.freeze
end
