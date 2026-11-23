require "administrate/base_dashboard"

class TranscriptCopyDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session_id: Field::Number,
    bucket: Field::String,
    manifest_object: Field::String,
    manifest_generation: Field::Number,
    transcript_object: Field::String,
    transcript_generation: Field::Number,
    transcript_digest: Field::String,
    transcript_byte_size: Field::Number,
    transcript_line_count: Field::Number,
    transcript_compressed_bytes: Field::Number,
    conversation_byte_size: Field::Number,
    conversation_compressed_bytes: Field::Number,
    subagents: Field::String.with_options(searchable: false),
    subagents_fingerprint: Field::String,
    verified_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  DELIBERATELY_OMITTED = [].freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    session_id
    transcript_byte_size
    verified_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # Read-only: see Supervisor::TranscriptCopiesController.
  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze
end
