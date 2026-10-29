require "administrate/base_dashboard"

class TestflightFeedbackDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    asc_id: Field::String,
    kind: Field::String,
    submitted_at: Field::DateTime,
    build_number: Field::String,
    device_model: Field::String,
    os_version: Field::String,
    comment: Field::Text,
    tester_email: Field::String,
    crash_log: Field::Text.with_options(searchable: false),
    crash_log_fetched_at: Field::DateTime,
    raw_attributes: Field::String.with_options(searchable: false),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    asc_id
    kind
    submitted_at
    build_number
    device_model
    os_version
    crash_log_fetched_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only. A row is what App Store Connect reported; an edited one would
  # no longer be that.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(feedback)
    "TestFlight #{feedback.kind} #{feedback.asc_id}"
  end
end
