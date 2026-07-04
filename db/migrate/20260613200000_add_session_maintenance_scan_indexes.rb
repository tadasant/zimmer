# frozen_string_literal: true

class AddSessionMaintenanceScanIndexes < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :sessions,
      [ :status, :trash_after ],
      name: "index_sessions_on_status_trash_after_with_clone_path",
      where: "(metadata->>'clone_path') IS NOT NULL",
      algorithm: :concurrently

    add_index :sessions,
      "status, (metadata->>'clone_path')",
      name: "index_sessions_on_status_clone_path_expression",
      where: "(metadata->>'clone_path') IS NOT NULL",
      algorithm: :concurrently
  end
end
