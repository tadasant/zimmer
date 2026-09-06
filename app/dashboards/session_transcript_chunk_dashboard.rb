require "administrate/base_dashboard"

class SessionTranscriptChunkDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Every column on `session_transcript_chunks` is either here or in
  # DELIBERATELY_OMITTED below — test/dashboards/dashboard_schema_coverage_test.rb
  # enforces that.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    seq: Field::Number,
    byte_size: Field::Number,
    line_count: Field::Number,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # DELIBERATELY_OMITTED
  DELIBERATELY_OMITTED = [
    # Up to 256 KiB of raw JSONL per row. The panel exists to answer "how is this
    # session's transcript laid out", which `seq`/`byte_size`/`line_count` answer;
    # rendering the bytes would make an index page of a long session unusable, and
    # /sessions/:id streams the conversation properly.
    :content
  ].freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    id
    session
    seq
    byte_size
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = ATTRIBUTE_TYPES.keys.freeze

  # FORM_ATTRIBUTES
  # Empty on purpose. A chunk is one slice of an append-only log whose neighbours'
  # offsets depend on it; hand-editing one through a generic form would corrupt the
  # transcript it belongs to rather than repair it.
  FORM_ATTRIBUTES = [].freeze

  # COLLECTION_FILTERS
  COLLECTION_FILTERS = {}.freeze
end
