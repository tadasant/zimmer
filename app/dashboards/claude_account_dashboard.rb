require "administrate/base_dashboard"

class ClaudeAccountDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    email: Field::String,
    status: Field::String,
    is_current: Field::Boolean,
    priority: Field::Number,
    quota_hit_count: Field::Number,
    stale_refresh_failures: Field::Number,
    last_stale_refresh_failure_at: Field::DateTime,
    last_rotated_to_at: Field::DateTime,
    quota_snapshots: Field::HasMany,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    email
    status
    is_current
    priority
    quota_hit_count
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    email
    status
    is_current
    priority
    quota_hit_count
    stale_refresh_failures
    last_stale_refresh_failure_at
    last_rotated_to_at
    quota_snapshots
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    email
    status
    priority
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
