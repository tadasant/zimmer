require "administrate/base_dashboard"

class TokenUsageBackfillDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    transcript_root: Field::String,
    cursor: Field::String,
    trigger: Field::String,
    directories_done: Field::Number,
    directories_total: Field::Number,
    files_scanned: Field::Number,
    session_rows: Field::Number,
    adhoc_rows: Field::Number,
    started_at: Field::DateTime,
    finished_at: Field::DateTime,
    last_ran_at: Field::DateTime,
    last_error: Field::Text,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    trigger
    started_at
    finished_at
    directories_done
    directories_total
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only: a row is the record of a sweep that happened. Hand-setting
  # `finished_at` would assert coverage nothing read, and hand-clearing it would
  # collide with the partial unique index that keeps one run in flight. Ask for a
  # re-scan from the Costs page instead — that is what the button is for.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
