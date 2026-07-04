class AddLastBroadcastToIndexAtToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :last_broadcast_to_index_at, :datetime
  end
end
