class AddExecutionFieldsToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :repository_url, :string
    add_column :sessions, :branch, :string, default: "main", null: false
    add_column :sessions, :execution_provider, :string, default: "local_filesystem", null: false

    add_index :sessions, :execution_provider
  end
end
