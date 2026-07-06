require "administrate/base_dashboard"

class McpOauthCredentialDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    server_name: Field::String,
    server_url: Field::String,
    credential_key: Field::String,
    client_id: Field::String,
    client_secret: Field::String.with_options(searchable: false),
    access_token: Field::Text.with_options(searchable: false),
    refresh_token: Field::Text.with_options(searchable: false),
    expires_at: Field::DateTime,
    scopes: Field::String,
    token_endpoint: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    id
    server_name
    server_url
    expires_at
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    server_name
    server_url
    credential_key
    client_id
    client_secret
    expires_at
    scopes
    token_endpoint
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  FORM_ATTRIBUTES = %i[
    server_name
    server_url
    credential_key
    client_id
    client_secret
    access_token
    refresh_token
    expires_at
    scopes
    token_endpoint
  ].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(mcp_oauth_credential)
    "#{mcp_oauth_credential.server_name}"
  end
end
