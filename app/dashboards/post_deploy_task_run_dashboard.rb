require "administrate/base_dashboard"

class PostDeployTaskRunDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    version: Field::String,
    name: Field::String,
    status: Field::String,
    attempts: Field::Number,
    failures: Field::Number,
    cursor: Field::String.with_options(searchable: false),
    stats: Field::String.with_options(searchable: false),
    started_at: Field::DateTime,
    finished_at: Field::DateTime,
    last_ran_at: Field::DateTime,
    next_attempt_at: Field::DateTime,
    last_error: Field::Text,
    last_error_at: Field::DateTime,
    locked_at: Field::DateTime,
    locked_by: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    version
    name
    status
    attempts
    finished_at
    last_error_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only. A row is the record of whether a one-time step ran against this
  # environment, and hand-setting `status` to succeeded would assert an
  # application nothing performed — the exact lie the ledger exists to prevent.
  # Re-arm a failed task from the health page instead; that is what the button
  # is for.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(run)
    "#{run.version} #{run.name}"
  end
end
