# frozen_string_literal: true

# What came back from work a Live conversation started, waiting for the person's
# next turn (LiveConversations::BackgroundResults).
class CreateLiveBackgroundResults < ActiveRecord::Migration[8.1]
  def change
    create_table :live_background_results do |t|
      t.references :live_conversation, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :root_session_id, null: false
      t.references :session, null: false, foreign_key: { on_delete: :cascade }
      t.string :event_id, null: false
      t.string :kind, null: false
      t.text :message
      t.datetime :occurred_at, null: false
      t.datetime :offered_at
      t.string :offered_claim
      t.bigint :offered_conversation_id
      t.bigint :offered_turn_id
      t.datetime :delivered_at
      t.bigint :delivered_after_turn_id
      t.datetime :raised_at
      t.datetime :dropped_at
      t.string :drop_reason
      t.timestamps

      t.index %i[live_conversation_id event_id], unique: true, name: "index_live_background_results_once"
      t.index :created_at, where: "raised_at IS NULL AND dropped_at IS NULL", name: "index_live_background_results_waiting"
    end
  end
end
