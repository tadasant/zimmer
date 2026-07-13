# Persisted last-known-good resolved AIR catalog tree.
#
# AirCatalogService writes a snapshot after every successful `air resolve` and
# falls back to it when a later resolve fails — for example when an upstream
# catalog introduces a cross-scope shortname collision that makes
# `air resolve --no-scope` hard-fail. Persisting in the DB (rather than only
# in process memory) means the fallback survives container restarts and is
# shared across the web and worker processes, so a broken upstream catalog can
# never take session creation — most importantly the zimmer-router lookup behind
# every routable message — down to zero.
class CreateCatalogSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :catalog_snapshots do |t|
      t.jsonb :entries, null: false
      t.datetime :resolved_at, null: false

      t.timestamps
    end

    add_index :catalog_snapshots, :resolved_at
  end
end
