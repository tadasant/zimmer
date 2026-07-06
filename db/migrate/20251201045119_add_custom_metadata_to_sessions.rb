class AddCustomMetadataToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :custom_metadata, :jsonb, default: {}
  end
end
