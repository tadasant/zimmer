require "administrate/base_dashboard"

class TokenUsageFeatureDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    request_id: Field::String,
    feature: Field::String,
    session: Field::BelongsTo,
    agent_root: Field::String,
    model: Field::String,
    subagent: Field::Boolean,
    called_at: Field::DateTime,
    input_tokens: Field::Number,
    output_tokens: Field::Number,
    cache_read_tokens: Field::Number,
    cache_creation_tokens: Field::Number,
    cache_creation_5m_tokens: Field::Number,
    cache_creation_1h_tokens: Field::Number,
    chars: Field::Number,
    occurrences: Field::Number,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    called_at
    feature
    agent_root
    model
    cache_read_tokens
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only, and for a stronger reason than its parent table's. These rows are
  # an ESTIMATE that ContextFeatureAttributor derives from transcript content and
  # scales against the request's real totals; hand-editing one would break the
  # arithmetic that keeps the parts from exceeding the whole, and the next
  # re-ingest would not correct it — `(request_id, feature)` makes ingestion a
  # no-op on rows that already exist. To change a figure, change the detector or
  # the attributor and delete the affected rows so a re-scan rewrites them.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
