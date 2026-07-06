class AddCatalogHooksToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :catalog_hooks, :jsonb, default: []
  end
end
