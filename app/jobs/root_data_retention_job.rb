# frozen_string_literal: true

# Deletes AgentRootRecord rows whose `expires_at` has passed, and keeps
# AgentRootRecordCounter in step with what it deleted.
#
# `expires_at` is fixed on each row when it is written, from the collection's
# `retention_days` as declared then. This job reads that column and nothing
# else — never the catalog — so a stale, changed or unresolvable catalog cannot
# make it delete a row early or late.
#
# The selector is `index_agent_root_records_on_expiry`, a partial index over
# `(expires_at, id) WHERE expires_at IS NOT NULL`, so a tick with nothing due is
# one index probe, and rows in collections with no retention are never scanned.
#
# Each batch is split by (namespace, collection), and each group is deleted in
# its own transaction that locks that collection's counter row FIRST — the same
# lock order RootData::Store takes — so a concurrent write cannot interleave
# between the delete and the decrement, and the two cannot deadlock.
#
# Idempotent and bounded: a run with nothing expired deletes nothing, and a
# backlog drains SLICE_BUDGET at a time across ticks.
class RootDataRetentionJob < ApplicationJob
  include SingletonSweep

  queue_as :default

  BATCH_SIZE = 1_000
  SLICE_BUDGET = 60.seconds

  def perform(now: Time.current, budget: SLICE_BUDGET, batch_size: BATCH_SIZE)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget.to_f
    total = 0

    loop do
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      candidates = AgentRootRecord.expired(now).order(:expires_at, :id).limit(batch_size)
        .pluck(:id, :namespace, :collection)
      break if candidates.empty?

      candidates.group_by { |_, namespace, collection| [ namespace, collection ] }.each do |(namespace, collection), rows|
        total += prune_group(namespace, collection, rows.map(&:first), now)
      end

      break if candidates.size < batch_size
    end

    Rails.logger.info("[RootDataRetentionJob] deleted #{total} expired root data record(s)") if total.positive?

    { deleted: total }
  end

  private

  def prune_group(namespace, collection, ids, now)
    AgentRootRecord.transaction do
      counter = AgentRootRecordCounter.lock.find_by(namespace: namespace, collection: collection)

      # Re-read under the counter lock: a put may have moved a row's expiry since
      # the batch was selected.
      rows = AgentRootRecord.where(id: ids).expired(now).pluck(:id, :data_bytes)
      next 0 if rows.empty?

      deleted = AgentRootRecord.where(id: rows.map(&:first)).delete_all

      if counter
        counter.records_count = [ counter.records_count - deleted, 0 ].max
        counter.data_bytes = [ counter.data_bytes - rows.sum(&:last), 0 ].max
        counter.save!
      end

      deleted
    end
  end
end
