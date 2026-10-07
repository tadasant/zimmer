# frozen_string_literal: true

# Zimmer as an OAuth 2.1 authorization server for its own `POST /mcp`, so a remote
# MCP client (Claude.ai's custom connectors, the MCP Inspector) can connect with no
# static API key. The opposite direction from `mcp_oauth_credentials`, which is
# Zimmer as an OAuth *client* of other MCP servers — hence the `oauth_server_`
# prefix on every table here.
#
# Every client is public (`token_endpoint_auth_method: none`, PKCE instead of a
# secret), so there are no client secrets to store. Authorization codes, access
# tokens and refresh tokens are stored as SHA-256 digests: the plaintext exists
# only in the HTTP response that issued it.
class CreateOauthServerTables < ActiveRecord::Migration[8.1]
  def change
    # A client that has registered (DCR, RFC 7591) or whose Client ID Metadata
    # Document has been fetched and validated (CIMD). For a CIMD client the row is
    # a cache of the document, keyed by its URL, re-fetched once
    # `metadata_expires_at` passes.
    create_table :oauth_server_clients do |t|
      t.string :client_id, null: false
      t.string :registration_type, null: false
      t.string :client_name
      t.string :client_uri
      t.jsonb :redirect_uris, null: false, default: []
      t.jsonb :grant_types, null: false, default: []
      t.datetime :metadata_expires_at
      t.datetime :last_used_at

      t.timestamps
    end
    add_index :oauth_server_clients, :client_id, unique: true

    # A single-use, short-lived code minted by /oauth/authorize after the human
    # consents, redeemed once at /oauth/token with the PKCE verifier.
    create_table :oauth_server_authorization_codes do |t|
      t.references :oauth_server_client, null: false, foreign_key: { on_delete: :cascade }
      t.string :code_digest, null: false
      t.string :redirect_uri, null: false
      t.string :code_challenge, null: false
      t.string :resource, null: false
      t.string :scope
      t.string :user_email, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at

      t.timestamps
    end
    add_index :oauth_server_authorization_codes, :code_digest, unique: true

    # One human's consent to one client: the connection the settings page lists and
    # can revoke. Every access and refresh token descends from exactly one grant, so
    # revoking the grant ends the connection however many rotations deep it is.
    create_table :oauth_server_grants do |t|
      t.references :oauth_server_client, null: false, foreign_key: { on_delete: :cascade }
      t.string :user_email, null: false
      t.string :resource, null: false
      t.string :scope
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.string :revocation_reason

      t.timestamps
    end

    # Access and refresh tokens. A refresh token is spent by the exchange that
    # rotates it (`rotated_at`); presenting a spent one again is replay, and
    # revokes the grant.
    create_table :oauth_server_tokens do |t|
      t.references :oauth_server_grant, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :rotated_at

      t.timestamps
    end
    add_index :oauth_server_tokens, :token_digest, unique: true
    add_index :oauth_server_tokens, :expires_at
  end
end
