require "administrate/base_dashboard"

# The token broker's child tokens (McpBrokeredToken). Read-only: the broker
# mints and revokes every row, and the token itself is masked.
class McpBrokeredTokenDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    grant: Field::BelongsTo.with_options(class_name: "McpBrokerGrant"),
    mcp_broker_grant_id: Field::Number,
    session: Field::BelongsTo,
    purpose: Field::String,
    label: Field::String,
    scope: Field::String,
    token: MaskedSecretField,
    state: Field::String,
    expires_at: Field::DateTime,
    revoke_requested_at: Field::DateTime,
    next_revoke_attempt_at: Field::DateTime,
    revoked_at: Field::DateTime,
    revoke_attempts: Field::Number,
    last_revoke_error: Field::Text,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id label scope state expires_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id grant mcp_broker_grant_id session purpose label scope token state expires_at
    revoke_requested_at next_revoke_attempt_at revoked_at revoke_attempts last_revoke_error
    created_at updated_at
  ].freeze

  FORM_ATTRIBUTES = [].freeze

  COLLECTION_FILTERS = {}.freeze

  def display_resource(row)
    "Brokered token #{row.label} (#{row.state})"
  end
end
