# frozen_string_literal: true

require "test_helper"
# stub_root_data_catalog stubs AgentRootsConfig.all.
require "mocha/minitest"

class RootDataRetentionJobTest < ActiveJob::TestCase
  include RootDataHelpers

  setup do
    @root = root_data_root("zimmer", data_collections: { "notes" => { "retention_days" => 7 }, "forever" => {} })
    @written_at = Time.zone.parse("2026-10-01 00:00:00")
    @store = RootData::Store.new(namespace: "zimmer", root: @root, now: @written_at)
  end

  test "deletes rows past expires_at, keeps the rest, and decrements the counter" do
    expired = @store.append(collection: "notes", data: { "n" => 1 })
    kept = RootData::Store.new(namespace: "zimmer", root: @root, now: @written_at + 5.days)
      .append(collection: "notes", data: { "n" => 2 })
    forever = @store.append(collection: "forever", data: { "n" => 3 })

    result = RootDataRetentionJob.perform_now(now: @written_at + 8.days)

    assert_equal 1, result[:deleted]
    assert_equal 0, result[:counters_corrected], "Store kept the counters in step"
    assert_not AgentRootRecord.exists?(expired.id)
    assert AgentRootRecord.exists?(kept.id)
    assert AgentRootRecord.exists?(forever.id)

    counter = AgentRootRecordCounter.find_by(namespace: "zimmer", collection: "notes")
    assert_equal 1, counter.records_count
    assert_equal kept.data_bytes, counter.data_bytes
  end

  test "reads only expires_at: a catalog that dropped the retention cannot save or delete a row" do
    expired = @store.append(collection: "notes", data: { "n" => 1 })
    # The catalog changing after the write has no bearing on the sweep.
    stub_root_data_catalog(root_data_root("zimmer", data_collections: { "notes" => {} }))

    RootDataRetentionJob.perform_now(now: @written_at + 8.days)
    assert_not AgentRootRecord.exists?(expired.id)
  end

  test "reconciles a counter that drifted from its rows, once it has been quiet" do
    kept = @store.append(collection: "forever", data: { "n" => 1 })
    # A row written around RootData::Store, and a counter edited by hand.
    AgentRootRecord.create!(namespace: "zimmer", collection: "forever", data: { "n" => 2 }, data_bytes: 9)
    counter = AgentRootRecordCounter.find_by(namespace: "zimmer", collection: "forever")
    counter.update_columns(records_count: RootData::Limits::MAX_RECORDS_PER_COLLECTION, updated_at: @written_at)

    result = RootDataRetentionJob.perform_now(now: @written_at + 2.hours)

    assert_equal 1, result[:counters_corrected]
    assert_equal 2, counter.reload.records_count
    assert_equal kept.data_bytes + 9, counter.data_bytes
    assert_equal 0, RootDataRetentionJob.perform_now(now: @written_at + 2.hours)[:counters_corrected],
                 "a recounted counter leaves the rotation until it is quiet again"
  end

  test "drains in batches and is a no-op when nothing is due" do
    3.times { |i| @store.append(collection: "notes", data: { "n" => i }) }

    assert_equal 3, RootDataRetentionJob.perform_now(now: @written_at + 8.days, batch_size: 2)[:deleted]
    assert_equal 0, RootDataRetentionJob.perform_now(now: @written_at + 8.days)[:deleted]
    assert_equal 0, AgentRootRecordCounter.find_by(collection: "notes").records_count
  end
end
