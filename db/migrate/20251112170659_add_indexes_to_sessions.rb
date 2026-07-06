class AddIndexesToSessions < ActiveRecord::Migration[8.0]
  def change
    add_index :sessions, :status
    add_index :sessions, :created_at
    add_index :sessions, :agent_type
  end
end
