require "administrate/base_dashboard"

class ElicitationDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    request_id: Field::String,
    status: Field::String,
    mode: Field::String,
    message: Field::Text,
    requested_schema: Field::String.with_options(searchable: false),
    meta: Field::String.with_options(searchable: false),
    tool_name: Field::String,
    context: Field::Text,
    mcp_session_id: Field::String,
    expires_at: Field::DateTime,
    response_content: Field::String.with_options(searchable: false),
    responded_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[
    id
    session
    request_id
    status
    tool_name
    expires_at
  ].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id
    session
    request_id
    status
    mode
    message
    requested_schema
    meta
    tool_name
    context
    mcp_session_id
    expires_at
    response_content
    responded_at
    created_at
    updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[
    session
    request_id
    status
    mode
    message
    tool_name
    context
    expires_at
  ].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(elicitation)
    "Elicitation #{elicitation.request_id} (#{elicitation.status})"
  end
end
