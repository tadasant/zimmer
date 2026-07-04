# Stores OAuth credentials for MCP servers that require OAuth authentication.
#
# These credentials are used to authenticate with OAuth-protected MCP servers
# when spawning agent sessions. Credentials are keyed by server_name and
# server_url_hash to uniquely identify each OAuth-protected server.
#
# The credential_key format is "server_name|url_hash" where url_hash is the
# first 16 chars of SHA256(compact_json({type, url, headers})).
class CreateMcpOauthCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :mcp_oauth_credentials do |t|
      # Server identification
      t.string :server_name, null: false
      t.string :server_url, null: false
      t.string :credential_key, null: false  # Format: "server_name|hash"

      # OAuth client registration
      t.string :client_id, null: false
      t.string :client_secret  # Optional, used by some OAuth providers

      # OAuth tokens
      t.text :access_token, null: false
      t.text :refresh_token
      t.datetime :expires_at
      t.string :scopes

      # Token refresh endpoint
      t.string :token_endpoint

      t.timestamps

      t.index :credential_key, unique: true
      t.index [ :server_name, :server_url ], unique: true
    end
  end
end
