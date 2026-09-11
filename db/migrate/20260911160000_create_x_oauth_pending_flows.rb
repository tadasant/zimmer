# frozen_string_literal: true

# The cross-leg state of the X (Twitter) OAuth consent flow (#852).
#
# Between "send the operator to X's consent page" and "exchange the code X hands
# back", the flow has to remember the PKCE code_verifier, the `state` it sent, the
# redirect URI (X compares the one on the exchange with the one on the consent
# request), and which XOauthCredential the result belongs to. The `x_oauth:*` rake
# tasks kept that in a JSON file on the box, which is what made the flow need a
# shell. This table is that file, moved into the database so the Supervisor
# controller can run both legs.
#
# A row is short-lived and single-use: XOauthPendingFlow.claim! deletes it on the
# first callback that names its state, and one past expires_at is refused.
class CreateXOauthPendingFlows < ActiveRecord::Migration[8.0]
  def change
    create_table :x_oauth_pending_flows do |t|
      t.string :state, null: false
      t.string :code_verifier, null: false
      t.string :redirect_uri, null: false
      t.string :account_key, null: false
      t.string :access_token_env_var, null: false
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :x_oauth_pending_flows, :state, unique: true
    add_index :x_oauth_pending_flows, :access_token_env_var
    add_index :x_oauth_pending_flows, :expires_at
  end
end
