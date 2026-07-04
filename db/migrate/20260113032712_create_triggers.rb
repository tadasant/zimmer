class CreateTriggers < ActiveRecord::Migration[8.0]
  def change
    create_table :triggers do |t|
      t.string :name, null: false
      t.string :trigger_type, null: false, default: "slack"
      t.jsonb :configuration, null: false, default: {}
      t.string :status, null: false, default: "enabled"

      # Session template
      t.string :agent_root_name, null: false
      t.jsonb :mcp_servers, null: false, default: []
      t.text :stop_condition
      t.text :prompt_template, null: false

      # Polling state
      t.datetime :last_polled_at
      t.datetime :last_triggered_at
      t.string :last_message_ts
      t.integer :sessions_created_count, default: 0

      t.timestamps
    end

    add_index :triggers, :status
    add_index :triggers, :trigger_type
  end
end
