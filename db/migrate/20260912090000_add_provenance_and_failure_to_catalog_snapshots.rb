# The catalog snapshot becomes every process's source of truth for the resolved
# tree (#98), so it has to carry the facts a process used to read off its own
# ~/.air/cache — and the health of the catalog, which a process that no longer
# resolves cannot observe for itself:
#
#   - fetched_at: when the writer's provider clones were last fetched (the
#     "Updated X ago" indicator), read from its FETCH_HEAD mtimes.
#   - catalog_shas: the commit each pinnable catalog resolved to on the writer's
#     disk, by ref — what the settings page shows as live.
#   - failed_at / failure_message: set when a later attempt to supersede this
#     snapshot failed, so every process can report the catalog as degraded.
#
# All four are nullable or defaulted, so containers still running the previous
# release keep inserting rows without knowing the columns exist.
class AddProvenanceAndFailureToCatalogSnapshots < ActiveRecord::Migration[8.0]
  def change
    add_column :catalog_snapshots, :fetched_at, :datetime
    add_column :catalog_snapshots, :catalog_shas, :jsonb, null: false, default: {}
    add_column :catalog_snapshots, :failed_at, :datetime
    add_column :catalog_snapshots, :failure_message, :text
  end
end
