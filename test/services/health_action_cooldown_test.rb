# frozen_string_literal: true

require "test_helper"

class HealthActionCooldownTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  # === fingerprint ===

  test "fingerprint is a truncated SHA-256 of the key, not the key" do
    fingerprint = HealthActionCooldown.fingerprint("sk-live-abc123")

    assert_equal Digest::SHA256.hexdigest("sk-live-abc123")[0, 32], fingerprint
    assert_not_includes fingerprint, "sk-live-abc123"
    assert_equal 32, fingerprint.length
  end

  test "different keys fingerprint differently" do
    assert_not_equal HealthActionCooldown.fingerprint("one"), HealthActionCooldown.fingerprint("two")
  end

  test "a missing key collapses to one shared anonymous bucket" do
    assert_equal HealthActionCooldown::ANONYMOUS, HealthActionCooldown.fingerprint(nil)
    assert_equal HealthActionCooldown::ANONYMOUS, HealthActionCooldown.fingerprint("")
  end

  # === keys ===

  test "the key names the action and the caller" do
    cooldown = HealthActionCooldown.new("abc123")

    assert_equal "health_api_rate_limit:cleanup_processes:abc123", cooldown.key("cleanup_processes")
  end

  test "a blank fingerprint falls back to the anonymous bucket" do
    assert_equal(
      "health_api_rate_limit:archive_old:#{HealthActionCooldown::ANONYMOUS}",
      HealthActionCooldown.new(nil).key("archive_old")
    )
  end

  # === limiting ===

  test "an unrecorded action is not limited" do
    assert_not HealthActionCooldown.new("abc").limited?("cleanup_processes")
  end

  test "a recorded action is limited for the cooldown window" do
    cooldown = HealthActionCooldown.new("abc")
    cooldown.record("cleanup_processes")

    assert cooldown.limited?("cleanup_processes")

    travel(HealthActionCooldown::COOLDOWN + 1.second) do
      assert_not cooldown.limited?("cleanup_processes")
    end
  end

  test "buckets are independent across actions and callers" do
    HealthActionCooldown.new("abc").record("cleanup_processes")

    assert_not HealthActionCooldown.new("abc").limited?("archive_old")
    assert_not HealthActionCooldown.new("xyz").limited?("cleanup_processes")
  end

  test "two objects with the same fingerprint share a bucket" do
    HealthActionCooldown.new("abc").record("retry_sessions")

    assert HealthActionCooldown.new("abc").limited?("retry_sessions")
  end

  # === fail closed ===

  test "a null store reports limited rather than silently never limiting" do
    Rails.cache = ActiveSupport::Cache::NullStore.new
    cooldown = HealthActionCooldown.new("abc")

    assert_not cooldown.store_usable?
    assert cooldown.limited?("cleanup_processes")
  end

  test "recording against a null store is a no-op rather than an error" do
    Rails.cache = ActiveSupport::Cache::NullStore.new

    assert_nothing_raised { HealthActionCooldown.new("abc").record("cleanup_processes") }
  end

  # The failure that matters in production. :redis_cache_store is configured with
  # an error_handler that logs and swallows, so a dead Redis does not raise: the
  # store is not a NullStore, `write` returns nil, and `read` returns nil. A
  # limiter that only asked `is_a?(NullStore)` would answer "not limited" forever.
  test "a store whose writes silently fail is treated as unusable" do
    Rails.cache = BrokenStore.new
    cooldown = HealthActionCooldown.new("abc")

    assert_not cooldown.store_usable?
    assert cooldown.limited?("cleanup_processes")
  end

  test "the probe is memoized, so a usable store is checked once per instance" do
    cooldown = HealthActionCooldown.new("abc")

    assert cooldown.store_usable?
    assert cooldown.store_usable?
    assert_not cooldown.limited?("cleanup_processes")
  end

  # Mimics ActiveSupport::Cache::RedisCacheStore with an error_handler in front
  # of an unreachable Redis: never raises, never stores, reads back nothing.
  class BrokenStore < ActiveSupport::Cache::Store
    def write(*, **)
      nil
    end

    def read(*, **)
      nil
    end

    def delete(*, **)
      false
    end

    def clear(**)
      nil
    end
  end
end
