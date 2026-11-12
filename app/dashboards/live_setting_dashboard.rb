require "administrate/base_dashboard"

# The Live settings row. Read-only: every write goes through
# LiveConversations::SettingsUpdate (on /live/settings, REST, MCP or the live
# model's own function), which validates it and records it in the history; an
# edit form here would do neither.
class LiveSettingDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    text_model: Field::String,
    text_temperature: Field::Number.with_options(decimals: 2),
    text_max_output_tokens: Field::Number,
    voice_model: Field::String,
    voice_reasoning_effort: Field::String,
    voice_name: Field::String,
    voice_speed: Field::Number.with_options(decimals: 2),
    voice_max_output_tokens: Field::Number,
    voice_turn_detection: Field::String,
    voice_vad_eagerness: Field::String,
    voice_vad_threshold: Field::Number.with_options(decimals: 2),
    voice_vad_prefix_padding_ms: Field::Number,
    voice_vad_silence_duration_ms: Field::Number,
    voice_noise_reduction: Field::String,
    voice_transcription_model: Field::String,
    voice_listening: Field::String,
    voice_telemetry: Field::String,
    guidance: Field::Text,
    updated_by: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id text_model voice_model voice_speed updated_by updated_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id text_model text_temperature text_max_output_tokens voice_model voice_reasoning_effort voice_name voice_speed voice_max_output_tokens voice_turn_detection voice_vad_eagerness voice_vad_threshold voice_vad_prefix_padding_ms voice_vad_silence_duration_ms voice_noise_reduction voice_transcription_model voice_listening voice_telemetry
    guidance updated_by created_at updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
