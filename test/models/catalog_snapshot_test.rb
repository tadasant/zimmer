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
    record = CatalogSnapshot.store!(roots: { "zimmer-router" => { "name" => "zimmer-router" } })

    assert record.persisted?
    assert record.resolved_at
    # Read back from the DB so jsonb's string keys are reflected (the in-memory
    # record still holds the symbol keys it was created with).
    stored = CatalogSnapshot.find(record.id)
    assert_equal({ "name" => "zimmer-router" }, stored.entries["roots"]["zimmer-router"])
  end

  test "store! retains only the most recent snapshot" do
    CatalogSnapshot.store!(roots: { "first" => {} })
    CatalogSnapshot.store!(roots: { "second" => {} })

    assert_equal 1, CatalogSnapshot.count
    assert_equal [ "second" ], CatalogSnapshot.latest.entries["roots"].keys
  end

  test "latest returns nil when no snapshot has been stored" do
    assert_nil CatalogSnapshot.latest
  end

  test "entries presence is validated" do
    assert_raises(ActiveRecord::RecordInvalid) do
      CatalogSnapshot.create!(resolved_at: Time.current)
    end
  end
end
