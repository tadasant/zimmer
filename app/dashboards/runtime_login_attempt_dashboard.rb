require "administrate/base_dashboard"

class RuntimeLoginAttemptDashboard < Administrate::BaseDashboard
  # pasted_code is deliberately omitted from every attribute set: it holds a
  # single-use authorization code and must never be surfaced in the admin UI.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    claude_account: Field::BelongsTo,
    runtime: Field::String,
    status: Field::String,
    pid: Field::Number,
    verification_url: Field::String,
    verification_code: Field::String,
    error_message: Field::Text,
    expires_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    claude_account
    runtime
    status
    created_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    claude_account
    runtime
    status
    pid
    verification_url
    verification_code
    error_message
    expires_at
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
