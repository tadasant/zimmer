require "administrate/base_dashboard"

class McpOauthPendingFlowDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    session: Field::BelongsTo,
    server_name: Field::String,
    server_url: Field::String,
    state: Field::String,
    code_verifier: Field::String.with_options(searchable: false),
    authorization_endpoint: Field::String,
    token_endpoint: Field::String,
    registration_endpoint: Field::String,
    client_id: Field::String,
    client_secret: Field::String.with_options(searchable: false),
    redirect_uri: Field::String,
    scopes: Field::String,
    mcp_server_config: Field::String.with_options(searchable: false),
    expires_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    id
    session
    server_name
    expires_at
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    session
    server_name
    server_url
    state
    authorization_endpoint
    token_endpoint
    registration_endpoint
    client_id
    redirect_uri
    scopes
    expires_at
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  FORM_ATTRIBUTES = %i[
    session
    server_name
    server_url
    state
    code_verifier
    authorization_endpoint
    token_endpoint
    registration_endpoint
    client_id
    client_secret
    redirect_uri
    scopes
    mcp_server_config
    expires_at
  ].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(mcp_oauth_pending_flow)
    "#{mcp_oauth_pending_flow.server_name} (Session ##{mcp_oauth_pending_flow.session_id})"
  end
end
