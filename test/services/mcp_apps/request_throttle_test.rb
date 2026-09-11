# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpApps::RequestThrottleTest < ActiveSupport::TestCase
  # The test environment's store is a :null_store, whose `increment` answers nil
  # — which is the throttle's fail-open path and nothing else. Counting at all
  # needs a store that counts.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @session = sessions(:waiting)
  end

  teardown do
    Rails.cache = @original_cache
  end

  test "allows a burst up to the ceiling and refuses past it" do
    McpApps::RequestThrottle::LIMIT.times do |i|
      assert McpApps::RequestThrottle.allow?(@session, "rpc"), "call #{i + 1} should be allowed"
    end

    refute McpApps::RequestThrottle.allow?(@session, "rpc")
    refute McpApps::RequestThrottle.allow?(@session, "rpc")
  end

  test "a chatty widget cannot spend the quota that keeps the agent reachable" do
    (McpApps::RequestThrottle::LIMIT + 5).times { McpApps::RequestThrottle.allow?(@session, "rpc") }

    assert McpApps::RequestThrottle.allow?(@session, "message"),
      "the message bucket is counted separately from the proxy bucket"
  end

  test "one session's views cannot throttle another's" do
    McpApps::RequestThrottle::LIMIT.times { McpApps::RequestThrottle.allow?(@session, "rpc") }

    assert McpApps::RequestThrottle.allow?(sessions(:needs_input), "rpc")
  end

  test "the window resets" do
    McpApps::RequestThrottle::LIMIT.times { McpApps::RequestThrottle.allow?(@session, "rpc") }
    refute McpApps::RequestThrottle.allow?(@session, "rpc")

    travel_to(McpApps::RequestThrottle::WINDOW.from_now + 1.second) do
      assert McpApps::RequestThrottle.allow?(@session, "rpc")
    end
  end

  test "a cache that cannot answer leaves the feature working rather than off" do
    Rails.cache.stubs(:increment).returns(nil)

    100.times { assert McpApps::RequestThrottle.allow?(@session, "rpc") }
  end
end
