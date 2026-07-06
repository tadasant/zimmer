class AddLastTimelineEntryAtToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :last_timeline_entry_at, :datetime
  end
end
