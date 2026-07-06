class AddSessionNotesToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :session_notes, :text
    add_column :sessions, :session_notes_updated_at, :datetime
  end
end
