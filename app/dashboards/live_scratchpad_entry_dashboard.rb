require "administrate/base_dashboard"

# One note on a live conversation's scratchpad. Read-only: notes are written by
# the conversation's assistant and its person through LiveConversations::Scratchpad,
# which holds the limits.
class LiveScratchpadEntryDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    live_conversation: Field::BelongsTo,
    body: Field::Text,
    written_by: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id live_conversation written_by updated_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[id live_conversation written_by body created_at updated_at].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
