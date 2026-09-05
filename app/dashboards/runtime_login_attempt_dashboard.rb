require "administrate/base_dashboard"

class RuntimeLoginAttemptDashboard < Administrate::BaseDashboard
  # pasted_code is deliberately omitted from every attribute set: it holds a
  # single-use authorization code and must never be surfaced in the admin UI.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    claude_account: Field::BelongsTo,
    account_email: Field::String,
    runtime: Field::String,
    status: Field::String,
    pid: Field::Number,
    verification_url: Field::String,
    verification_code: Field::String,
    error_message: Field::Text,
    expires_at: Field::DateTime,
    heartbeat_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # DELIBERATELY_OMITTED
  # columns that exist on the table and are intentionally not rendered here.
  # test/dashboards/dashboard_schema_coverage_test.rb reads this, so an omission
  # is a reviewed decision rather than a gap nobody noticed.
  DELIBERATELY_OMITTED = [
    # The authorization code a human pastes back from the runtime's login page —
    # a credential that exchanges for an account token. /supervisor is behind a
    # single shared password, so this is not something to render there.
    :pasted_code
  ].freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    claude_account
    account_email
    runtime
    status
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    claude_account
    account_email
    runtime
    status
    pid
    verification_url
    verification_code
    error_message
    expires_at
    heartbeat_at
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
