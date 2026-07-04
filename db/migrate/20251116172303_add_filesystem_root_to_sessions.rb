class AddFilesystemRootToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :filesystem_root, :string
  end
end
