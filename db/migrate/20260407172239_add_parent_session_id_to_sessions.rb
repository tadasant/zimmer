class AddParentSessionIdToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :parent_session_id, :bigint
    add_index :sessions, :parent_session_id

    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE sessions
          SET parent_session_id = COALESCE(
            (custom_metadata->>'heartbeat_session_id')::bigint,
            (custom_metadata->>'parent_session_id')::bigint
          )
          WHERE (custom_metadata->>'heartbeat_session_id') IS NOT NULL
             OR (custom_metadata->>'parent_session_id') IS NOT NULL
        SQL
      end
    end
  end
end
