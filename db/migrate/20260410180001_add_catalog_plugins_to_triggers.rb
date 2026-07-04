class AddCatalogPluginsToTriggers < ActiveRecord::Migration[8.0]
  def change
    add_column :triggers, :catalog_plugins, :jsonb, default: [], null: false
  end
end
