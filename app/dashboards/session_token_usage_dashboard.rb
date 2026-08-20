require "administrate/base_dashboard"

class SessionTokenUsageDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    request_id: Field::String,
    session: Field::BelongsTo,
    agent_root: Field::String,
    runtime_session_id: Field::String,
    agent_runtime: Field::String,
    model: Field::String,
    subagent: Field::Boolean,
    input_tokens: Field::Number,
    output_tokens: Field::Number,
    cache_read_tokens: Field::Number,
    cache_creation_tokens: Field::Number,
    cache_creation_5m_tokens: Field::Number,
    cache_creation_1h_tokens: Field::Number,
    web_search_requests: Field::Number,
    web_fetch_requests: Field::Number,
    service_tier: Field::String,
    called_at: Field::DateTime,
    transcript_path: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    called_at
    agent_root
    model
    session
    output_tokens
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only: rows are measurements of API calls that already happened, written by
  # TokenUsageIngestionService from transcripts. Hand-editing one would assert spend
  # that Anthropic never reported. To correct a row, fix the ingestion and re-run —
  # `request_id` makes that idempotent.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
