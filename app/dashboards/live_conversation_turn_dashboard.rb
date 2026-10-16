require "administrate/base_dashboard"

# One turn of a live conversation. Read-only, like the conversation: turns are
# what was said and what a tool returned, written by the conversation itself.
class LiveConversationTurnDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    live_conversation: Field::BelongsTo,
    role: Field::String,
    source: Field::String,
    content: Field::Text,
    tool_name: Field::String,
    call_id: Field::String,
    tool_arguments: Field::String.with_options(searchable: false),
    tool_output: Field::Text,
    tool_error: Field::Boolean,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id live_conversation role tool_name created_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id live_conversation role source content tool_name call_id tool_arguments tool_output tool_error created_at updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
