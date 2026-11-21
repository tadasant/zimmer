# frozen_string_literal: true

# The session token broker (TokenBroker): one parent grant per authorization
# server, held only by the backend, and the short-lived child tokens minted
# under it for each session turn and for Zimmer's own calls.
#
# Every secret column here is Active Record–encrypted from its first write.
# There is no plaintext copy of any of them, so unlike McpOauthCredential's
# token twins there is no expand/contract to run later.
#
# Both tables are new and empty, so this deploy needs no backfill, and old
# containers serving during the cutover never read them. The one change to an
# existing table is a nullable column on `mcp_oauth_pending_flows`, which old
# containers ignore.
class CreateTokenBrokerTables < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_broker_grants do |t|
      t.string :authorization_server, null: false
      t.string :issuer
      t.string :token_endpoint, null: false
      t.string :revocation_endpoint
      t.string :resource, null: false
      t.string :client_id, null: false
      t.text :access_token
      t.text :refresh_token
      t.datetime :access_token_expires_at
      t.string :scope
      t.string :status, null: false, default: "active"
      t.text :last_error
      t.datetime :last_refreshed_at
      t.datetime :consented_at
      t.timestamps
    end
    add_index :mcp_broker_grants, :authorization_server, unique: true

    create_table :mcp_brokered_tokens do |t|
      t.references :mcp_broker_grant, null: false, foreign_key: { on_delete: :cascade }
      t.references :session, null: true, foreign_key: { on_delete: :nullify }
      t.string :purpose, null: false
      t.string :label, null: false
      t.string :scope, null: false
      t.text :token, null: false
      t.string :state, null: false, default: "live"
      t.datetime :expires_at, null: false
      t.datetime :revoke_requested_at
      t.datetime :next_revoke_attempt_at
      t.datetime :revoked_at
      t.integer :revoke_attempts, null: false, default: 0
      t.text :last_revoke_error
      t.timestamps
    end
    add_index :mcp_brokered_tokens, [ :session_id, :state ]
    add_index :mcp_brokered_tokens, [ :state, :next_revoke_attempt_at ]
    add_index :mcp_brokered_tokens, [ :mcp_broker_grant_id, :purpose, :scope, :state ],
      name: "index_mcp_brokered_tokens_on_grant_purpose_scope_state"

    add_column :mcp_oauth_pending_flows, :broker_authorization_server, :string
  end
end
