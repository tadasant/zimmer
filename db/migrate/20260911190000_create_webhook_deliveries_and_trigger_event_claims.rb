# frozen_string_literal: true

# The two dedup stores behind webhook ingress (#217).
#
# webhook_deliveries is one row per provider delivery Zimmer accepted, keyed on the
# provider's own delivery id (Slack's `event_id`). A provider redelivers on a timeout or a
# non-2xx, and the unique index is what turns the second copy into a no-op.
#
# trigger_event_claims is one row per (trigger condition, external event) that fired or was
# folded into a session, whichever path saw it first. It is what lets a webhook and the poller
# that backs it watch the same channel without the same message firing twice: both claim before
# they fire, inside the transaction that creates the session, and the loser of the unique
# index fires nothing.
#
# Both are Postgres rather than Redis on purpose: the claim has to commit or roll back with the
# session it records, and production's redis_cache_store answers a failed write with nil rather
# than an error, which would turn a Redis blip into duplicate sessions.
class CreateWebhookDeliveriesAndTriggerEventClaims < ActiveRecord::Migration[8.0]
  def change
    create_table :webhook_deliveries do |t|
      t.string :source, null: false
      t.string :delivery_id, null: false
      t.string :event_type
      t.integer :retry_num
      t.datetime :created_at, null: false
    end

    add_index :webhook_deliveries, [ :source, :delivery_id ], unique: true
    add_index :webhook_deliveries, :created_at

    create_table :trigger_event_claims do |t|
      t.references :trigger_condition, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :event_key, null: false
      t.string :claimed_via, null: false
      t.string :group_key
      t.decimal :anchor_ts, precision: 17, scale: 6
      t.references :session, foreign_key: { on_delete: :nullify }
      t.datetime :created_at, null: false
    end

    add_index :trigger_event_claims, [ :trigger_condition_id, :event_key ], unique: true
    add_index :trigger_event_claims, [ :trigger_condition_id, :group_key, :anchor_ts ]
    add_index :trigger_event_claims, :created_at
  end
end
