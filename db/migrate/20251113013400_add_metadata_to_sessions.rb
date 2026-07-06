class AddMetadataToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :metadata, :json, default: {}
  end
end
