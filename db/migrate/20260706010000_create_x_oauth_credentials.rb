# frozen_string_literal: true

# Durable, runtime-writable store for X (Twitter) OAuth 2.0 user-context tokens.
#
# X rotates refresh tokens SINGLE-USE: every refresh returns a brand-new refresh
# token and invalidates the prior one. A static seed in Rails encrypted
# credentials (git-committed, deploy-time) therefore works for at most one
# refresh. This table is the runtime-writable home for the rotating token, so
# each rotation is persisted and survives restarts/deploys — the same reason
# Proctor's rotating OAuth tokens live in a DB row rather than credentials.
#
# The static, non-rotating confidential-client creds (client id + secret) do NOT
# live here — they stay in Rails credentials (mcp_secrets: X_OAUTH_CLIENT_ID /
# X_OAUTH_CLIENT_SECRET), mirroring how the gmail servers keep their static
# client creds. Only the rotating tokens are stored on the row.
class CreateXOauthCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :x_oauth_credentials do |t|
      # Human-facing identifier for the authorized account (e.g. "tadasayy").
      t.string :account_key, null: false
      # The .mcp.json env var this credential vends the access token as. The
      # SecretsInterpolator resolves ${access_token_env_var} to a fresh access
      # token at session-prep. Keyed here so multiple X accounts can coexist,
      # each surfaced under its own env var.
      t.string :access_token_env_var, null: false

      # Rotating tokens (the whole point of this table).
      t.text :access_token
      t.text :refresh_token
      t.datetime :expires_at

      t.string :scopes
      t.string :token_endpoint, null: false, default: "https://api.x.com/2/oauth2/token"

      # Refresh bookkeeping (mirrors the Proctor refresher's error/cooldown model).
      t.datetime :last_refreshed_at
      t.datetime :last_refresh_attempted_at
      t.string :last_refresh_error

      t.timestamps
    end

    add_index :x_oauth_credentials, :account_key, unique: true
    add_index :x_oauth_credentials, :access_token_env_var, unique: true
  end
end
