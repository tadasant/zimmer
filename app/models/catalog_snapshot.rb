# frozen_string_literal: true

# The resolved AIR catalog tree, persisted — the one copy every process serves.
#
# In production the web (Puma) and worker (GoodJob) run in separate containers
# with separate ~/.air/cache directories. Only a process that has just fetched
# its provider clones can resolve a fresh tree, so resolving is a write: the
# process that runs `air update` + `air resolve` stores the result here, and
# every process — including the one that wrote it — serves the newest row on its
# in-memory TTL (see AirCatalogService#sync_from_snapshot). The same row is the
# last-known-good fallback when a later resolve fails.
#
# Besides the tree it carries what a reader cannot learn from its own disk:
# when the writer last fetched (fetched_at), which commit each pinnable catalog
# resolved to (catalog_shas), and whether the most recent attempt to replace
# this row failed (failed_at / failure_message).
#
# Only the most recent snapshot is retained; store! prunes older rows.
class CatalogSnapshot < ApplicationRecord
  # The columns a process reads on every TTL check. Everything except the tree,
  # so deciding whether there is anything new costs one narrow query.
  HEADER_COLUMNS = %i[id resolved_at failed_at failure_message].freeze

  validates :entries, presence: true
  validates :resolved_at, presence: true

  # The most recently resolved snapshot, or nil if none has been stored yet.
  def self.latest
    order(resolved_at: :desc).first
  end

  # The newest snapshot without its entry tree, or nil. The TTL check reads
  # this and only loads the tree (#latest) when the row is one it is not
  # already serving.
  def self.latest_header
    order(resolved_at: :desc).select(*HEADER_COLUMNS).first
  end

  # Persist the given resolved entry tree as the new snapshot, pruning older
  # rows so the table holds only the latest. `entries` is the type-keyed tree
  # produced by AirCatalogService (e.g. {skills: {...}, ...}); jsonb
  # serialization stringifies the top-level keys, which AirCatalogService
  # re-symbolizes on read. A new row starts healthy: failed_at is nil.
  def self.store!(entries, fetched_at: nil, catalog_shas: {})
    record = create!(entries: entries, resolved_at: Time.current, fetched_at: fetched_at, catalog_shas: catalog_shas)
    where.not(id: record.id).delete_all
    record
  end

  # Mark the newest snapshot as superseded-and-failed: the most recent attempt
  # to refresh the catalog did not produce a new one, so whoever serves this row
  # is serving a last-known-good tree. Cleared by the next store!, which writes
  # a fresh row. `message` must already be scrubbed of credentials. Returns the
  # number of rows updated (0 when no snapshot exists yet).
  def self.record_failure!(message, at: Time.current)
    where(id: order(resolved_at: :desc).limit(1).select(:id))
      .update_all(failed_at: at, failure_message: message)
  end

  # The recorded failure as the {message:, at:} hash AirCatalogService exposes
  # through resolve_failure, or nil when this snapshot is healthy.
  def failure
    { message: failure_message.to_s, at: failed_at } if failed_at
  end
end
