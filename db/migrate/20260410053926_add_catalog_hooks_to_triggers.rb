class AddCatalogHooksToTriggers < ActiveRecord::Migration[8.0]
  def change
    add_column :triggers, :catalog_hooks, :jsonb, default: [], null: false
  end
end
