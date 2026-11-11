# frozen_string_literal: true

# One MCP Events webhook subscription Zimmer holds on a catalog server, for one `mcp_event`
# condition: see McpEventWebhookSubscription.
class CreateMcpEventWebhookSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_event_webhook_subscriptions do |t|
      # Nullified, not cascaded, when the condition is deleted: the row still has to say what to
      # unsubscribe from, and McpEventSubscriptionsJob deletes it once it has.
      t.references :trigger_condition, null: true, foreign_key: { on_delete: :nullify }
      t.string :token, null: false
      t.string :server, null: false
      t.string :event_name, null: false
      t.jsonb :arguments, null: false, default: {}
      t.string :callback_url, null: false
      t.text :secret_ciphertext, null: false
      t.string :state, null: false, default: "pending"
      t.string :remote_id
      t.text :cursor
      t.datetime :subscribed_at
      t.datetime :refresh_before
      t.datetime :verified_at
      t.datetime :last_delivery_at
      t.jsonb :delivery_status
      t.string :last_error
      t.integer :failures, null: false, default: 0
      t.datetime :next_attempt_at
      t.timestamps
    end
    add_index :mcp_event_webhook_subscriptions, :token, unique: true
  end
end
