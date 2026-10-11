require "administrate/base_dashboard"

class AgentRootRecordCounterDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    namespace: Field::String,
    collection: Field::String,
    records_count: Field::Number,
    data_bytes: Field::Number,
    window_started_at: Field::DateTime,
    window_writes: Field::Number,
    last_written_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    namespace
    collection
    records_count
    data_bytes
    last_written_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    namespace
    collection
    records_count
    data_bytes
    window_started_at
    window_writes
    last_written_at
    created_at
    updated_at
  ].freeze

  # Read-only: the counters are maintained in the same transaction as the rows
  # they count (RootData::Store, RootDataRetentionJob). A hand-edited count
  # would move the row cap.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
