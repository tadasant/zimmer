# Stores pending OAuth flows initiated through the bridge.
#
# When a user clicks the OAuth authorization link for an MCP server, this record
# stores the OAuth flow state while they complete authentication with the OAuth
# provider. Contains all information needed to exchange the authorization code
# for tokens.
#
# Lifecycle:
# - Created by McpOauthController#initiate when user starts OAuth flow
# - Used by McpOauthController#callback to exchange code for tokens
# - Deleted after successful token exchange or after expiration (24 hours)
#
# The `state` parameter serves dual purposes:
# 1. CSRF protection in the OAuth flow
# 2. Lookup key to resume the flow after OAuth provider callback
class CreateMcpOauthPendingFlows < ActiveRecord::Migration[8.0]
  def change
    create_table :mcp_oauth_pending_flows do |t|
      # Links to the session waiting for OAuth completion
      t.references :session, null: false, foreign_key: true

      # MCP server identification
      t.string :server_name, null: false
      t.string :server_url, null: false

      # OAuth state parameter (for CSRF protection and flow lookup)
      t.string :state, null: false

      # PKCE code verifier (for secure token exchange)
      t.string :code_verifier, null: false

      # OAuth endpoints discovered during flow initiation
      t.string :authorization_endpoint, null: false
      t.string :token_endpoint, null: false
      t.string :registration_endpoint

      # Client credentials (from DCR or pre-registered)
      t.string :client_id, null: false
      t.string :client_secret
      t.string :redirect_uri, null: false

      # Requested scopes
      t.string :scopes

      # MCP server config (stored for credential key computation)
      t.jsonb :mcp_server_config, null: false

      # Flow expiration
      t.datetime :expires_at, null: false

      t.timestamps

      t.index :state, unique: true
      t.index [ :session_id, :server_name ], unique: true
      t.index :expires_at
    end
  end
end
