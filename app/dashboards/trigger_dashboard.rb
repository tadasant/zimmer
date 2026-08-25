require "administrate/base_dashboard"

class TriggerDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    name: Field::String,
    status: Field::String,
    agent_root_name: Field::String,
    mcp_servers: Field::String.with_options(searchable: false),
    goal: Field::Text,
    prompt_template: Field::Text,
    last_triggered_at: Field::DateTime,
    failed_at: Field::DateTime,
    last_error: Field::Text,
    sessions_created_count: Field::Number,
    reuse_session: Field::Boolean,
    enqueue_messages: Field::Boolean,
    skip_if_pending_session: Field::Boolean,
    last_session_id: Field::Number,
    trigger_conditions: Field::HasMany,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    name
    status
    sessions_created_count
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    name
    status
    agent_root_name
    mcp_servers
    goal
    prompt_template
    last_triggered_at
    failed_at
    last_error
    sessions_created_count
    reuse_session
    enqueue_messages
    skip_if_pending_session
    last_session_id
    trigger_conditions
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    name
    status
    agent_root_name
    mcp_servers
    goal
    prompt_template
  ].freeze

  COLLECTION_FILTERS = {}.freeze
end
