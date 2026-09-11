require "administrate/base_dashboard"

class WorkflowRunDashboard < Administrate::BaseDashboard
  # Every column on `workflow_runs` is here — test/dashboards/dashboard_schema_coverage_test.rb
  # enforces it.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    workflow_id: Field::String,
    session: Field::BelongsTo,
    # Blank once the trigger that fired the run is deleted: the run outlives it.
    trigger: Field::BelongsTo,
    # What the run was started with and bound to: the validated input, and the
    # trusted identifiers the workflow's #plan resolved.
    input: Field::String.with_options(searchable: false),
    resolved: Field::String.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    workflow_id
    session
    trigger
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Deliberately empty. A WorkflowRun is read-only once written — #readonly?
  # refuses every save through a record — and its `resolved` identifiers are only
  # worth trusting if nothing but the workflow's #plan wrote them. The Supervisor
  # route offers index and show only.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
