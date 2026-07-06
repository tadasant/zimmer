class CreateElicitations < ActiveRecord::Migration[8.0]
  def change
    create_table :elicitations do |t|
      t.references :session, null: false, foreign_key: true
      t.string :request_id, null: false
      t.string :status, default: "pending", null: false
      t.string :mode, null: false
      t.text :message, null: false
      t.jsonb :requested_schema, null: false, default: {}
      t.jsonb :meta, default: {}
      t.string :tool_name
      t.text :context
      t.string :mcp_session_id
      t.datetime :expires_at
      t.jsonb :response_content
      t.datetime :responded_at

      t.timestamps
    end

    add_index :elicitations, :request_id, unique: true
    add_index :elicitations, [ :session_id, :status ]
    add_index :elicitations, :expires_at
  end
end
