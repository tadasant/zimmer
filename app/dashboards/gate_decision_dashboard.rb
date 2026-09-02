require "administrate/base_dashboard"

class GateDecisionDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    gate: Field::String,
    surface: Field::String,
    artifact_url: Field::String,
    decided_at: Field::Date,
    decision: Field::String,
    producing_session_url: Field::String,
    writing_session: Field::BelongsTo,
    recorded_via: Field::String,
    feedbacks: Field::HasMany,
    payload: Field::String.with_options(searchable: false),
    source_key: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    id
    gate
    surface
    decision
    decided_at
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    gate
    surface
    artifact_url
    decided_at
    decision
    producing_session_url
    writing_session
    recorded_via
    feedbacks
    payload
    source_key
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  #
  # Deliberately empty, and the route offers index and show only. A GateDecision
  # is append-only — it raises ActiveRecord::ReadOnlyRecord on update and on
  # destroy — because the ledger is only worth what the guarantee that it cannot
  # be edited after the fact is worth. A correction is a new row, recorded
  # through the API or the MCP tool, never an edit here.
  FORM_ATTRIBUTES = %i[].freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  COLLECTION_FILTERS = {
    pr_merge: ->(resources) { resources.for_gate(GateDecision::PR_MERGE) },
    issue_work: ->(resources) { resources.for_gate(GateDecision::ISSUE_WORK) },
    held: ->(resources) { resources.with_decision("hold") },
    with_human_feedback: ->(resources) { resources.with_human_feedback }
  }.freeze
end
