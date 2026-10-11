require "administrate/base_dashboard"

class AgentRootRecordDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    namespace: Field::String,
    collection: Field::String,
    key: Field::String,
    data: Field::String.with_options(searchable: false),
    data_bytes: Field::Number,
    expires_at: Field::DateTime,
    writing_session: Field::BelongsTo,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    namespace
    collection
    key
    data_bytes
    updated_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    namespace
    collection
    key
    data
    data_bytes
    expires_at
    writing_session
    created_at
    updated_at
  ].freeze

  # Deliberately empty, and the route offers index and show only. Every write
  # goes through RootData::Store, which holds the caps and keeps
  # AgentRootRecordCounter in step; a row edited or deleted here would skip both.
  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
