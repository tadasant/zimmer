# frozen_string_literal: true

# The running totals for one (namespace, collection) of AgentRootRecord, so the
# row cap, the usage report on /health and `list_root_collections` never count
# the records table.
#
# Maintained only by RootData::Store and RootDataRetentionJob, in the same
# transaction as the rows they change. Also the lock a writer takes: every
# write to a collection first locks its counter row, which serializes that
# collection's writers so the row cap and the rate limit hold under concurrency.
class AgentRootRecordCounter < ApplicationRecord
  validates :namespace, :collection, presence: true

  scope :for_namespace, ->(namespace) { where(namespace: namespace) }

  # Per-namespace totals, for /health and `get_system_health`. Reads the counter
  # table only, which holds one row per collection that has ever been written.
  def self.usage_by_namespace
    group(:namespace)
      .order(:namespace)
      .pluck(
        :namespace,
        Arel.sql("COUNT(*)"),
        Arel.sql("SUM(records_count)"),
        Arel.sql("SUM(data_bytes)"),
        Arel.sql("MAX(last_written_at)")
      )
      .map do |namespace, collections, records, bytes, last_written_at|
        { namespace: namespace, collections: collections.to_i, records: records.to_i,
          data_bytes: bytes.to_i, last_written_at: last_written_at }
      end
  end
end
