class AddSessionIdToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :session_id, :string
    add_index :sessions, :session_id, unique: true
  end
end
