require "administrate/base_dashboard"

class WorkBacklogItemDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    key: Field::String,
    issue_url: Field::String,
    repo: Field::String,
    surface: Field::String,
    title: Field::String,
    kind: Field::String,
    scope_direction: Field::String,
    estimated_cost: Field::String,
    gate_verdict: Field::String,
    decided_at: Field::Date,
    added_at: Field::DateTime,
    added_by: Field::String,
    added_via: Field::String,
    precedence: Field::Number,
    pinned: Field::Boolean,
    status: Field::String,
    writing_session: Field::BelongsTo,
    started_session: Field::BelongsTo,
    started_by_session: Field::BelongsTo,
    started_at: Field::DateTime,
    removed_at: Field::DateTime,
    removed_by: Field::String,
    removal_reason: Field::Text,
    payload: Field::String.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    id
    key
    status
    estimated_cost
    precedence
    pinned
    surface
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    key
    issue_url
    repo
    surface
    title
    kind
    scope_direction
    estimated_cost
    gate_verdict
    decided_at
    added_at
    added_by
    added_via
    precedence
    pinned
    status
    writing_session
    started_session
    started_by_session
    started_at
    removed_at
    removed_by
    removal_reason
    payload
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  #
  # Deliberately empty, and the route offers index and show only. Every write to
  # the queue goes through WorkBacklog::Ranking's lock and re-rank — the REST
  # controller and the MCP tools — and a row edited here would skip both.
  FORM_ATTRIBUTES = %i[].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {
    queued: ->(resources) { resources.queued },
    started: ->(resources) { resources.started },
    removed: ->(resources) { resources.removed },
    pinned: ->(resources) { resources.pinned_items },
    in_flight: ->(resources) { resources.in_flight }
  }.freeze
end
