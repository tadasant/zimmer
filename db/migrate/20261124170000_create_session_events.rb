# frozen_string_literal: true

# The log Zimmer's own MCP server publishes as MCP Events (SessionEvents), and
# the standing subscriptions Zimmer holds on the subscribers' behalf.
#
# `txid` is the writing transaction's id. A reader that pages by `id` alone can
# step over a row whose transaction committed after a later id was already read;
# reading only transactions older than every one still open, in (txid, id) order,
# cannot. See SessionEvents::Feed.
class CreateSessionEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :session_events do |t|
      t.string :event_id, null: false
      t.string :name, null: false
      t.references :session, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :parent_session_id
      t.string :agent_root
      t.jsonb :data, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.bigint :txid, null: false, default: -> { "(pg_current_xact_id())::text::bigint" }
      t.datetime :created_at, null: false

      t.index :event_id, unique: true
      t.index %i[name txid id]
      t.index :parent_session_id
      t.index :created_at
    end

    create_table :session_event_subscriptions do |t|
      t.references :session, null: false, foreign_key: { on_delete: :cascade }
      t.references :subscriber, null: false, polymorphic: true
      t.jsonb :event_names, null: false, default: []
      t.string :last_event_id
      t.datetime :last_event_at
      t.timestamps

      t.index %i[session_id subscriber_type subscriber_id], unique: true, name: "index_session_event_subscriptions_on_edge"
    end
  end
end
