# frozen_string_literal: true

class AddSessionMaintenanceIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :sessions,
      :id,
      where: "transcript IS NOT NULL",
      name: "index_sessions_on_id_where_transcript_present",
      algorithm: :concurrently

    add_index :sessions,
      [ :status, :archived_at, :id ],
      where: "trash_after IS NULL AND archived_at IS NOT NULL AND (metadata->>'clone_path') IS NOT NULL",
      name: "index_sessions_on_archived_stale_clone_candidates",
      algorithm: :concurrently

    add_index :sessions,
      [ :status, :updated_at, :id ],
      where: "trash_after IS NULL AND archived_at IS NULL AND (metadata->>'clone_path') IS NOT NULL",
      name: "index_sessions_on_legacy_archived_stale_clone_candidates",
      algorithm: :concurrently

    add_index :sessions,
      [ :status, :updated_at, :id ],
      where: "(metadata->>'clone_path') IS NOT NULL",
      name: "index_sessions_on_failed_stale_clone_candidates",
      algorithm: :concurrently
  end
end
