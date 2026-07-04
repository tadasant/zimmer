require "administrate/base_dashboard"

class ClaudeAccountQuotaSnapshotDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    claude_account: Field::BelongsTo,
    subscription_type: Field::String,
    rate_limit_tier: Field::String,
    utilization_5h: Field::Number.with_options(decimals: 4),
    utilization_7d: Field::Number.with_options(decimals: 4),
    status_5h: Field::String,
    status_7d: Field::String,
    reset_5h: Field::DateTime,
    reset_7d: Field::DateTime,
    overage_status: Field::String,
    trigger: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    claude_account
    utilization_5h
    utilization_7d
    trigger
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    claude_account
    subscription_type
    rate_limit_tier
    utilization_5h
    utilization_7d
    status_5h
    status_7d
    reset_5h
    reset_7d
    overage_status
    trigger
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
