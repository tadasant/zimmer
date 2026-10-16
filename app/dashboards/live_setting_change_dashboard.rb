require "administrate/base_dashboard"

# The Live settings history: one row per write, before → after, and who made
# it. Read-only — it is an audit record.
class LiveSettingChangeDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    changeset: Field::String.with_options(searchable: false),
    actor_kind: Field::String,
    actor: Field::String,
    live_conversation: Field::BelongsTo,
    created_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id actor_kind actor live_conversation created_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[id actor_kind actor live_conversation changeset created_at].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
