require "administrate/base_dashboard"

# Live Mode conversations. Read-only: a conversation is started, talked to,
# switched between typing and voice, and ended through /live and the API
# (LiveConversations::Actions), which hold its rules — one open conversation,
# the tool bridge — that an edit form here would walk around.
class LiveConversationDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    mode: Field::String,
    # Which client last drove the conversation (web, ios, carplay, mcp).
    client_surface: Field::String,
    status: Field::String,
    agent_root: Field::String,
    model: Field::String,
    title: Field::String,
    instructions: Field::Text,
    instructions_source: Field::String,
    mode_instructions: Field::String.with_options(searchable: false),
    mcp_servers: Field::String.with_options(searchable: false),
    mcp_tool_cache: Field::String.with_options(searchable: false),
    error_message: Field::Text,
    responding_since: Field::DateTime,
    last_activity_at: Field::DateTime,
    ended_at: Field::DateTime,
    turns: Field::HasMany.with_options(class_name: "LiveConversationTurn"),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id mode status agent_root model last_activity_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id mode client_surface status agent_root model title instructions_source mcp_servers mcp_tool_cache
    error_message responding_since last_activity_at ended_at instructions mode_instructions turns created_at updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[].freeze

  COLLECTION_FILTERS = {}.freeze
end
