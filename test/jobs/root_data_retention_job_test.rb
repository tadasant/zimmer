# frozen_string_literal: true

require "test_helper"

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

    assert_equal({ deleted: 1 }, result)
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

  test "drains in batches and is a no-op when nothing is due" do
    3.times { |i| @store.append(collection: "notes", data: { "n" => i }) }

    assert_equal({ deleted: 3 }, RootDataRetentionJob.perform_now(now: @written_at + 8.days, batch_size: 2))
    assert_equal({ deleted: 0 }, RootDataRetentionJob.perform_now(now: @written_at + 8.days))
    assert_equal 0, AgentRootRecordCounter.find_by(collection: "notes").records_count
  end
end
