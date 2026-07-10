require "administrate/base_dashboard"

class XOauthCredentialDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account_key: Field::String,
    access_token_env_var: Field::String,
    access_token: Field::Text.with_options(searchable: false),
    refresh_token: Field::Text.with_options(searchable: false),
    expires_at: Field::DateTime,
    scopes: Field::String,
    token_endpoint: Field::String,
    last_refreshed_at: Field::DateTime,
    last_refresh_attempted_at: Field::DateTime,
    last_refresh_error: Field::String,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  COLLECTION_ATTRIBUTES = %i[
    id
    account_key
    access_token_env_var
    expires_at
    last_refresh_error
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # Raw token values are intentionally omitted (rotating secrets).
  SHOW_PAGE_ATTRIBUTES = %i[
    id
    account_key
    access_token_env_var
    expires_at
    scopes
    token_endpoint
    last_refreshed_at
    last_refresh_attempted_at
    last_refresh_error
    created_at
    updated_at
  ].freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  FORM_ATTRIBUTES = %i[
    account_key
    access_token_env_var
    access_token
    refresh_token
    expires_at
    scopes
    token_endpoint
  ].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(x_oauth_credential)
    "#{x_oauth_credential.account_key} (#{x_oauth_credential.access_token_env_var})"
  end
end
