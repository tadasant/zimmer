require "administrate/base_dashboard"

class AdhocTokenUsageDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    request_id: Field::String,
    source: Field::String,
    subject_session_id: Field::Number,
    model: Field::String,
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
    metadata: Field::Text,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    called_at
    source
    model
    subject_session_id
    output_tokens
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only, for the same reason as SessionTokenUsageDashboard: these are
  # measurements of calls that already happened. `subject_session_id` is the session
  # the call was ABOUT, not one that made it — provenance, so it is a plain number
  # rather than a BelongsTo.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
