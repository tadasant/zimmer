require "administrate/base_dashboard"

# The Live voice-engine cost ledger (LiveUsageEvent). Read-only: rows are
# written by the engines and the voice clients' usage reports, priced on the
# way in, and rolled up on /live/costs; an edit here would change a recorded
# cost behind the caps' back.
class LiveUsageEventDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    live_conversation: Field::BelongsTo,
    engine: Field::String,
    mode: Field::String,
    operation: Field::String,
    vendor: Field::String,
    model: Field::String,
    input_tokens: Field::Number,
    output_tokens: Field::Number,
    cache_read_tokens: Field::Number,
    cache_write_tokens: Field::Number,
    audio_input_tokens: Field::Number,
    audio_output_tokens: Field::Number,
    seconds: Field::Number.with_options(decimals: 3),
    characters: Field::Number,
    count: Field::Number,
    cost_usd: Field::Number.with_options(decimals: 6),
    priced: Field::Boolean,
    billing_basis: Field::String,
    price_version: Field::String,
    latency_ms: Field::Number,
    first_audio_ms: Field::Number,
    error: Field::String,
    idempotency_key: Field::String,
    details: Field::String.with_options(searchable: false),
    occurred_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id occurred_at engine mode operation model cost_usd billing_basis latency_ms].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id live_conversation engine mode operation vendor model input_tokens output_tokens cache_read_tokens cache_write_tokens
    audio_input_tokens audio_output_tokens seconds characters count cost_usd priced billing_basis price_version latency_ms first_audio_ms
    error idempotency_key details occurred_at created_at updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
