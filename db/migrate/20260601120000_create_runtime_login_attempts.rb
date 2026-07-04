# frozen_string_literal: true

# Backs the UI-driven OAuth/device-auth "Authenticate" flow on the Quotas
# screen. Each row tracks one in-flight login for a ClaudeAccount: the web
# controller creates it and enqueues RuntimeLoginJob, the worker job (which
# holds the login CLI subprocess open) writes the verification URL/code and the
# terminal status back, and the UI polls the row to render progress. The row is
# also the cross-container message bus — the controller writes pasted_code /
# canceled here and the worker job reads them.
class CreateRuntimeLoginAttempts < ActiveRecord::Migration[8.0]
  def change
    create_table :runtime_login_attempts do |t|
      t.references :claude_account, null: false, foreign_key: true
      t.string :runtime, null: false
      t.string :status, null: false, default: "starting"
      t.string :verification_url
      # Codex device-auth one-time code (XXXX-XXXX). Short-lived; never logged.
      t.string :verification_code
      # Claude authorization code the user pastes back. Single-use and nulled the
      # instant the worker writes it to the CLI's stdin. Never logged.
      t.string :pasted_code
      t.text :error_message
      t.integer :pid
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :runtime_login_attempts, [ :claude_account_id, :created_at ]
    add_index :runtime_login_attempts, :status
  end
end
