class RenameRepositoryUrlToGitRootAndAddSubdirectory < ActiveRecord::Migration[8.0]
  def change
    rename_column :sessions, :repository_url, :git_root
    add_column :sessions, :subdirectory, :string
  end
end
