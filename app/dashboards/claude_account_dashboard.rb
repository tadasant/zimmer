require "administrate/base_dashboard"

class ClaudeAccountDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    email: Field::String,
    runtime: Field::String,
    status: Field::String,
    is_current: Field::Boolean,
    priority: Field::Number,
    quota_hit_count: Field::Number,
    stale_refresh_failures: Field::Number,
    last_stale_refresh_failure_at: Field::DateTime,
    last_rotated_to_at: Field::DateTime,
    reauth_alerted_at: Field::DateTime,
    quota_snapshots: Field::HasMany,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # DELIBERATELY_OMITTED
  # columns that exist on the table and are intentionally not rendered here.
  # test/dashboards/dashboard_schema_coverage_test.rb reads this, so an omission
  # is a reviewed decision rather than a gap nobody noticed.
  DELIBERATELY_OMITTED = [
    # The account's OAuth material — access token, refresh token, expiry. This is
    # the credential the whole fleet runs on, and /supervisor is a shared-password
    # panel, so it is not rendered and not editable here. Re-auth goes through the
    # runtime login flow, which never shows the token either.
    :oauth_config
  ].freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    email
    runtime
    status
    is_current
    priority
    quota_hit_count
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[
    email
    status
    priority
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
