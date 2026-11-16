require "administrate/base_dashboard"

class CycleTimeAnalysisDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    root_session: Field::BelongsTo.with_options(class_name: "Session"),
    eligible: Field::Boolean,
    ineligible_reason: Field::String,
    ineligible_detail: Field::Text,
    initiator: Field::String,
    initiator_detail: Field::String,
    title: Field::String,
    agent_root: Field::String,
    session_count: Field::Number,
    started_at: Field::DateTime,
    finished_at: Field::DateTime,
    wall_seconds: Field::Number.with_options(decimals: 1),
    category_seconds: Field::String.with_options(searchable: false),
    session_category_seconds: Field::String.with_options(searchable: false),
    dominant_wait_category: Field::String,
    top_segments: Field::String.with_options(searchable: false),
    algorithm_version: Field::Number,
    computed_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # The two segment arrays are the Gantt chart's drawing data — up to 20,000
  # entries — and are read on /cycle_times/:id, where they are drawn.
  DELIBERATELY_OMITTED = %i[lanes hierarchy_segments].freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    root_session
    eligible
    ineligible_reason
    title
    wall_seconds
    finished_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    root_session
    eligible
    ineligible_reason
    ineligible_detail
    initiator
    initiator_detail
    title
    agent_root
    session_count
    started_at
    finished_at
    wall_seconds
    category_seconds
    session_category_seconds
    dominant_wait_category
    top_segments
    algorithm_version
    computed_at
    created_at
    updated_at
  ].freeze

  # No form: see Supervisor::CycleTimeAnalysesController.
  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze
end
