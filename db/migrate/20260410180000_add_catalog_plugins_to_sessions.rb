class AddCatalogPluginsToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :catalog_plugins, :jsonb, default: []
  end
end
