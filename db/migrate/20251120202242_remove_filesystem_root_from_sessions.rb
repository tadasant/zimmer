class RemoveFilesystemRootFromSessions < ActiveRecord::Migration[8.0]
  def change
    remove_column :sessions, :filesystem_root, :string
  end
end
