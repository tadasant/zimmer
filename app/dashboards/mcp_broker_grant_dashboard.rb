require "administrate/base_dashboard"

# The token broker's parent grants (McpBrokerGrant). Read-only: a grant is
# created by the one-time consent on /token-broker and ended by its Disconnect,
# which revokes it at the authorization server first — deleting a row here
# would skip that. Both tokens are masked: the panel says whether each is set
# and never renders it.
class McpBrokerGrantDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    authorization_server: Field::String,
    issuer: Field::String,
    token_endpoint: Field::String,
    revocation_endpoint: Field::String,
    resource: Field::String,
    client_id: Field::String,
    access_token: MaskedSecretField,
    refresh_token: MaskedSecretField,
    access_token_expires_at: Field::DateTime,
    scope: Field::String,
    status: Field::String,
    last_error: Field::Text,
    last_refreshed_at: Field::DateTime,
    consented_at: Field::DateTime,
    brokered_tokens: Field::HasMany.with_options(class_name: "McpBrokeredToken"),
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id authorization_server status access_token_expires_at last_refreshed_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id authorization_server issuer token_endpoint revocation_endpoint resource client_id
    access_token refresh_token access_token_expires_at scope status last_error
    last_refreshed_at consented_at brokered_tokens created_at updated_at
  ].freeze

  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(grant)
    "Token broker grant for #{grant.authorization_server}"
  end
end
