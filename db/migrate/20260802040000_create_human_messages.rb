class CreateHumanMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :human_messages do |t|
      t.references :session, null: false, index: false,
                   foreign_key: { on_delete: :cascade }
      t.string :author, null: false
      t.string :channel, null: false
      t.text :content, null: false
      t.datetime :occurred_at, null: false
      t.jsonb :provenance, null: false, default: {}

      t.timestamps
    end

    # Always read session-scoped (or scoped to a set of sessions in one
    # hierarchy) and in chronological order.
    add_index :human_messages, [ :session_id, :occurred_at, :id ]

    # Session lineage is recorded on `parent_session_id` going forward, but
    # sessions spawned before that was wired carry the edge in
    # `custom_metadata->>'router_session_id'`. SessionHierarchy derives the tree
    # from both, so finding a session's children means querying that JSON path —
    # without this index that is a sequential scan of `sessions` on every render
    # of a session detail page.
    add_index :sessions, "((custom_metadata->>'router_session_id'))",
              name: "index_sessions_on_router_session_id"
  end
end
