# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class PollerHeartbeatTest < ActiveSupport::TestCase
  # A real store, not the null_store the test environment ships: every assertion here is
  # about what a write leaves behind for a later read.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "each poller has its own key, and the GitHub key is the one the poller has always stamped" do
    assert_equal "github_trigger_poller:last_successful_poll_at", PollerHeartbeat.cache_key(:github)
    assert_equal "slack_trigger_poller:last_successful_poll_at", PollerHeartbeat.cache_key(:slack)
    assert_not_equal PollerHeartbeat.cache_key(:github), PollerHeartbeat.cache_key(:slack)
  end

  test "an unknown poller is a KeyError at the call site, not a heartbeat nobody reads" do
    assert_raises(KeyError) { PollerHeartbeat.cache_key(:calendar) }
    assert_raises(KeyError) { PollerHeartbeat.stamp(:calendar) }
  end

  test "stamp records now and last_at reads it back" do
    travel_to Time.utc(2026, 9, 11, 12, 0, 0) do
      assert PollerHeartbeat.stamp(:slack)
      assert_equal Time.utc(2026, 9, 11, 12, 0, 0), PollerHeartbeat.last_at(:slack)
      assert_equal "2026-09-11T12:00:00Z", PollerHeartbeat.raw(:slack)
    end
  end

  test "stamping one poller leaves the other alone" do
    PollerHeartbeat.stamp(:github)

    assert_not_nil PollerHeartbeat.last_at(:github)
    assert_nil PollerHeartbeat.last_at(:slack)
  end

  test "the stamp carries a TTL long enough to hold a last-success time through an outage" do
    # The check needs to READ the stale value to know polling stopped; a key that expired
    # mid-outage would read as an undatable absence and be seeded instead of paged on.
    Rails.cache.expects(:write).with(
      PollerHeartbeat.cache_key(:github), anything, expires_in: PollerHeartbeat::TTL
    ).returns(true)

    PollerHeartbeat.stamp(:github)
    assert_operator PollerHeartbeat::TTL, :>=, 1.day
  end

  test "last_at is nil when nothing has been stamped" do
    assert_nil PollerHeartbeat.last_at(:github)
    assert_nil PollerHeartbeat.raw(:github)
  end

  test "last_at degrades an unreadable value to no baseline rather than raising" do
    Rails.cache.write(PollerHeartbeat.cache_key(:github), "not-a-timestamp")
    assert_nil PollerHeartbeat.last_at(:github)

    Rails.cache.write(PollerHeartbeat.cache_key(:github), 12_345)
    assert_nil PollerHeartbeat.last_at(:github)
  end

  test "a cache write failure is a WARN and a false, never an exception into the poller" do
    Rails.cache.stubs(:write).raises(Redis::CannotConnectError, "down")

    result = nil
    entries = capture_log_entries { result = PollerHeartbeat.stamp(:slack) }

    assert_equal false, result
    assert entries.any? { |severity, message| severity == "WARN" && message.include?("slack poll heartbeat") },
           "the failed stamp should be logged at WARN"
  end
end
