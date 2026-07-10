# frozen_string_literal: true

require "test_helper"

class EgressHealthCheckTest < ActiveSupport::TestCase
  # The production cache is null_store in test, which would make every
  # record/status round-trip a no-op. Swap in a real in-memory store, mirroring
  # SystemHealthMonitorJobTest.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.delete(EgressHealthCheck::CACHE_KEY)
  end

  teardown do
    Rails.cache = @original_cache
  end

  def degraded_result(detail: "boom", resolver: "127.0.0.11")
    EgressHealthCheck::Result.new(healthy: false, detail: detail, resolver: resolver)
  end

  def healthy_result(resolver: "127.0.0.11")
    EgressHealthCheck::Result.new(healthy: true, detail: "resolved", resolver: resolver)
  end

  test "probe is healthy when the primary resolver resolves any host" do
    probe = ->(host, _resolver) { host == "api.anthropic.com" }
    result = EgressHealthCheck.new(resolver: "127.0.0.11", probe: probe).probe
    assert result.healthy
    assert_equal "127.0.0.11", result.resolver
  end

  test "probe is degraded when the primary resolver resolves nothing" do
    result = EgressHealthCheck.new(resolver: "127.0.0.11", probe: ->(_h, _r) { false }).probe
    assert_not result.healthy
    assert_match(/could not resolve/, result.detail)
  end

  test "probe is skipped (treated healthy) when no resolver is configured" do
    result = EgressHealthCheck.new(resolver: nil, probe: ->(_h, _r) { false }).probe
    assert result.healthy
    assert_nil result.resolver
    assert_match(/no resolver/, result.detail)
  end

  test "record applies hysteresis: banner shows only after DISPLAY_THRESHOLD consecutive failures" do
    first = EgressHealthCheck.record(degraded_result)
    assert_equal "ok", first["status"], "one bad tick must not raise the banner"
    assert_equal 1, first["consecutive_failures"]
    assert_not EgressHealthCheck.degraded?

    second = EgressHealthCheck.record(degraded_result)
    assert_equal "degraded", second["status"], "sustained failure raises the banner"
    assert_equal 2, second["consecutive_failures"]
    assert second["degraded_since"].present?
    assert EgressHealthCheck.degraded?
  end

  test "record keeps degraded_since stable across sustained degraded ticks" do
    EgressHealthCheck.record(degraded_result)
    since = EgressHealthCheck.record(degraded_result)["degraded_since"]
    later = EgressHealthCheck.record(degraded_result)["degraded_since"]
    assert_equal since, later
  end

  test "record clears the streak and banner on a healthy probe" do
    EgressHealthCheck.record(degraded_result)
    EgressHealthCheck.record(degraded_result)
    assert EgressHealthCheck.degraded?

    stored = EgressHealthCheck.record(healthy_result)
    assert_equal "ok", stored["status"]
    assert_equal 0, stored["consecutive_failures"]
    assert_nil stored["degraded_since"]
    assert_not EgressHealthCheck.degraded?
  end

  test "status returns nil and never raises when the cache read fails" do
    Rails.cache.stub(:read, ->(*) { raise "redis is down" }) do
      assert_nil EgressHealthCheck.status
      assert_not EgressHealthCheck.degraded?
    end
  end
end
