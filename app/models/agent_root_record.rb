# frozen_string_literal: true

# One record in an agent root's persistent data store.
#
# A generic document row: `namespace` is the root it belongs to, `collection`
# the declared kind of record, `key` an optional upsert handle, and `data` the
# record itself. What a collection's records look like is declared in the AIR
# catalog (`data_collections` on the root) and checked on write — see
# RootData::Collections. Nothing about a collection's shape is a column.
#
# Write through RootData::Store, never directly: it is what resolves the caps,
# keeps AgentRootRecordCounter in step, and stamps `expires_at`. A row written
# around it is invisible to the row cap and the usage report until it is
# deleted, and it is deleted only by its own `expires_at`.
#
# `namespace` is derived server-side from the calling session (RootData::Namespace)
# and never accepted as an argument. That is a scoping rule, not an
# authorization one — see docs/sessions/root-data.md.
class AgentRootRecord < ApplicationRecord
  belongs_to :writing_session, class_name: "Session", optional: true

  validates :namespace, :collection, presence: true
  validates :key, length: { maximum: RootData::Limits::MAX_KEY_LENGTH }, allow_nil: true

  scope :in_collection, ->(namespace, collection) { where(namespace: namespace, collection: collection) }
  scope :expired, ->(now = Time.current) { where(expires_at: ...now) }

  # `data @> filter` — the jsonb containment the GIN `jsonb_path_ops` index serves.
  scope :containing, ->(filter) { where("agent_root_records.data @> ?::jsonb", filter.to_json) }
end
