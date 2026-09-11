# frozen_string_literal: true

require "test_helper"

class CatalogSnapshotTest < ActiveSupport::TestCase
  setup do
    # A real catalog snapshot can be persisted by any test that resolves the
    # catalog (or by app boot outside the test transaction); start from a clean
    # table so these tests control its contents explicitly.
    CatalogSnapshot.delete_all
  end

  test "store! persists the entry tree and a resolved_at timestamp" do
    record = CatalogSnapshot.store!({ roots: { "zimmer-router" => { "name" => "zimmer-router" } } })

    assert record.persisted?
    assert record.resolved_at
    # Read back from the DB so jsonb's string keys are reflected (the in-memory
    # record still holds the symbol keys it was created with).
    stored = CatalogSnapshot.find(record.id)
    assert_equal({ "name" => "zimmer-router" }, stored.entries["roots"]["zimmer-router"])
  end

  test "store! retains only the most recent snapshot" do
    CatalogSnapshot.store!({ roots: { "first" => {} } })
    CatalogSnapshot.store!({ roots: { "second" => {} } })

    assert_equal 1, CatalogSnapshot.count
    assert_equal [ "second" ], CatalogSnapshot.latest.entries["roots"].keys
  end

  test "latest returns nil when no snapshot has been stored" do
    assert_nil CatalogSnapshot.latest
  end

  test "store! records the writer's fetch time and catalog SHAs, and starts healthy" do
    fetched = Time.utc(2026, 9, 11, 8, 30)
    record = CatalogSnapshot.store!({ skills: { "a" => {} } },
      fetched_at: fetched, catalog_shas: { "github://o/r" => { "HEAD" => "a" * 40 } })

    stored = CatalogSnapshot.find(record.id)
    assert_equal fetched, stored.fetched_at
    assert_equal({ "github://o/r" => { "HEAD" => "a" * 40 } }, stored.catalog_shas)
    assert_nil stored.failure
  end

  test "record_failure! marks only the newest snapshot, and the next store! is healthy again" do
    CatalogSnapshot.store!({ skills: { "a" => {} } })
    at = Time.utc(2026, 9, 11, 9)

    assert_equal 1, CatalogSnapshot.record_failure!("air update failed", at: at)
    assert_equal({ message: "air update failed", at: at }, CatalogSnapshot.latest.failure)

    CatalogSnapshot.store!({ skills: { "b" => {} } })
    assert_nil CatalogSnapshot.latest.failure
  end

  test "record_failure! leaves a snapshot that superseded the failed attempt alone" do
    attempted_at = Time.utc(2026, 9, 11, 10)
    # A pin save (or another container's refresh) resolved successfully AFTER
    # this attempt began: the newest tree is fresh, so the failure is stale news.
    CatalogSnapshot.store!({ skills: { "fresh" => {} } })
    CatalogSnapshot.update_all(resolved_at: attempted_at + 2.seconds)

    assert_equal 0, CatalogSnapshot.record_failure!("air update failed", attempted_at: attempted_at)
    assert_nil CatalogSnapshot.latest.failure
  end

  test "record_failure! marks a snapshot the failed attempt was trying to supersede" do
    attempted_at = Time.utc(2026, 9, 11, 10)
    CatalogSnapshot.store!({ skills: { "stale" => {} } })
    CatalogSnapshot.update_all(resolved_at: attempted_at - 2.seconds)

    assert_equal 1, CatalogSnapshot.record_failure!("air update failed", attempted_at: attempted_at)
    assert_equal "air update failed", CatalogSnapshot.latest.failure[:message]
  end

  test "record_failure! is a no-op when no snapshot exists" do
    assert_equal 0, CatalogSnapshot.record_failure!("boom")
  end

  test "latest_header carries the health columns but not the tree" do
    CatalogSnapshot.store!({ skills: { "a" => {} } })
    CatalogSnapshot.record_failure!("boom")

    header = CatalogSnapshot.latest_header
    assert_equal CatalogSnapshot.latest.id, header.id
    assert_equal "boom", header.failure[:message]
    refute header.has_attribute?(:entries)
  end

  test "entries presence is validated" do
    assert_raises(ActiveRecord::RecordInvalid) do
      CatalogSnapshot.create!(resolved_at: Time.current)
    end
  end
end
