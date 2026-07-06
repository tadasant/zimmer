class AddAutoCompactWindowToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :auto_compact_window, :integer, default: 200_000, null: false
  end
end
