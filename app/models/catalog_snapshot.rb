# frozen_string_literal: true

# Persisted last-known-good resolved AIR catalog tree.
#
# AirCatalogService stores a snapshot after every successful `air resolve` and
# reads it back as a fallback when a later resolve fails (e.g. an upstream
# catalog introduces a cross-scope shortname collision, or a transient network
# failure breaks `air update`). Because it lives in the DB, the fallback
# survives process restarts and is shared across the web and worker processes —
# the in-memory cache alone would be empty on a freshly restarted container,
# which is exactly when a broken upstream catalog is most likely to surface.
#
# Only the most recent snapshot is retained; store! prunes older rows.
class CatalogSnapshot < ApplicationRecord
  validates :entries, presence: true
  validates :resolved_at, presence: true

  # The most recently resolved snapshot, or nil if none has been stored yet.
  def self.latest
    order(resolved_at: :desc).first
  end

  # Persist the given resolved entry tree as the new last-known-good snapshot,
  # pruning older rows so the table holds only the latest. `entries` is the
  # type-keyed tree produced by AirCatalogService (e.g. {skills: {...}, ...});
  # jsonb serialization stringifies the top-level keys, which AirCatalogService
  # re-symbolizes on read.
  def self.store!(entries)
    record = create!(entries: entries, resolved_at: Time.current)
    where.not(id: record.id).delete_all
    record
  end
end
