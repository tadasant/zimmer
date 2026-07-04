class CreateCatalogPins < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_pins do |t|
      # The github:// catalog prefix being pinned, e.g.
      # "github://tadasant/zimmer-catalog". One row per catalog.
      t.string :catalog, null: false
      # The git ref (commit SHA, tag, or branch) the catalog is frozen to.
      t.string :ref, null: false

      t.timestamps
    end

    add_index :catalog_pins, :catalog, unique: true
  end
end
