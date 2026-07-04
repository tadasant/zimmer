class AddIsAutonomousToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :is_autonomous, :boolean, default: true, null: false
  end
end
