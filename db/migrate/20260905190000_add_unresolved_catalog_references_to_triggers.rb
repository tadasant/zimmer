class AddUnresolvedCatalogReferencesToTriggers < ActiveRecord::Migration[8.0]
  # Bookkeeping for the catalog-reference heal, which no longer deletes a name
  # the catalog stopped resolving (zimmer#853). The column records which
  # references are currently unresolvable, and when each was first seen that
  # way, so the heal announces one exactly once instead of once an hour forever.
  #
  # Additive and reversible: every existing row gets `{}` and no trigger's
  # configuration is read or rewritten.
  def change
    add_column :triggers, :unresolved_catalog_references, :jsonb, default: {}, null: false
  end
end
