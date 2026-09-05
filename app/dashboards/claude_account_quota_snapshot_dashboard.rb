require "administrate/base_dashboard"

class ClaudeAccountQuotaSnapshotDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    claude_account: Field::BelongsTo,
    account_email: Field::String,
    account_runtime: Field::String,
    subscription_type: Field::String,
    rate_limit_tier: Field::String,
    utilization_5h: Field::Number.with_options(decimals: 4),
    utilization_7d: Field::Number.with_options(decimals: 4),
    status_5h: Field::String,
    status_7d: Field::String,
    reset_5h: Field::DateTime,
    reset_7d: Field::DateTime,
    overage_status: Field::String,
    overage_disabled_reason: Field::String,
    active_session_count: Field::Number,
    trigger: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    claude_account
    account_email
    utilization_5h
    utilization_7d
    trigger
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
