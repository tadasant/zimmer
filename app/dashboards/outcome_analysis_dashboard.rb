require "administrate/base_dashboard"

class OutcomeAnalysisDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    analyzer_session: Field::BelongsTo.with_options(class_name: "Session"),
    schema_version: Field::String,
    root: Field::Text,
    notes: Field::Text,
    agent_root: Field::String,
    agent_runtime: Field::String,
    model: Field::String,
    session_created_at: Field::DateTime,
    root_outcome: Field::String,
    segment_count: Field::Number,
    failure_segment_count: Field::Number,
    max_depth: Field::Number,
    analyzed_at: Field::DateTime,
    superseded_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    session
    root_outcome
    segment_count
    failure_segment_count
    analyzed_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only. An analysis is a reading a specific analyzer took of a specific
  # transcript; hand-editing one would forge that reading. A row saved in error is
  # superseded by saving another (the tool does that), or destroyed outright —
  # neither of which needs a form. The denormalized columns are derived from
  # `root` at save time, so an editable form could also put them out of step with
  # the tree they summarize.
  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze
end
