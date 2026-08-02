class CreateTimelineEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :timeline_events do |t|
      t.references :session, null: false, index: false,
                   foreign_key: { on_delete: :cascade }
      t.string :event_type, null: false, default: "human_message"
      t.string :author, null: false
      t.string :channel, null: false
      t.text :content, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :provenance, null: false, default: {}

      t.timestamps
    end

    # The timeline is always read session-scoped and in chronological order.
    add_index :timeline_events, [ :session_id, :occurred_at, :id ]
  end
end
