class AddCompositeIndexesToLogs < ActiveRecord::Migration[8.0]
  def change
    # Add composite index for common query pattern: logs ordered by created_at for a specific session
    add_index :logs, [ :session_id, :created_at ], name: "index_logs_on_session_id_and_created_at"

    # Add index for filtering by level (if needed for future queries)
    add_index :logs, :level, name: "index_logs_on_level"
  end
end
