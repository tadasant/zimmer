class CreateSessions < ActiveRecord::Migration[8.0]
  def change
    create_table :sessions do |t|
      t.string :agent_type, default: "claude_code"
      t.integer :status, default: 0
      t.json :config

      t.timestamps
    end
  end
end
