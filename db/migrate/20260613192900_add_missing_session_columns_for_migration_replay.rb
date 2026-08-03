# frozen_string_literal: true

class AddMissingSessionColumnsForMigrationReplay < ActiveRecord::Migration[8.0]
  def up
    unless column_exists?(:sessions, :repository_name)
      add_column :sessions, :repository_name, :string
    end

    unless column_exists?(:sessions, :transcript)
      add_column :sessions, :transcript, :json
    end
  end

  def down
    # Schema-loaded environments own these columns. Rolling back this replay
    # repair must not drop application data.
  end
end
