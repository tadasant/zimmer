# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class DeepHealthCheckTest < ActiveSupport::TestCase
  # A client that answers PING the way `redis` does, without a server.
  class FakeRedis
    def initialize(reply: "PONG", raising: nil)
      @reply = reply
      @raising = raising
    end

    def ping
      raise @raising if @raising

      @reply
    end
  end

  def setup
    @original_cache = Rails.cache
    # The test env runs a NullStore, which the cache check correctly calls
    # broken. Everything that is not specifically about that failure needs a
    # store that actually stores.
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @original_redis_url = ENV["REDIS_URL"]
    # Deterministic default: no Redis configured, so the redis check reports
    # `skipped` instead of depending on whether a server happens to be up.
    ENV.delete("REDIS_URL")
  end

  def teardown
    Mocha::Mockery.instance.teardown
    Rails.cache.clear
    Rails.cache = @original_cache
    ENV["REDIS_URL"] = @original_redis_url
  end

  test "reports ok when the database and cache both answer" do
    report = DeepHealthCheck.new.call

    assert_equal "ok", report[:status]
    assert_empty report[:failed]
    assert_equal "ok", report[:checks][:database][:status]
    assert_equal "ok", report[:checks][:cache][:status]
    assert_not_nil report[:checked_at]
  end

  test "an unconfigured Redis is skipped, not a failure" do
    report = DeepHealthCheck.new.call

    assert_equal "skipped", report[:checks][:redis][:status]
    assert_equal "ok", report[:status]
  end

  test "a NullStore cache is an error, and names itself" do
    Rails.cache = ActiveSupport::Cache::NullStore.new

    report = DeepHealthCheck.new.call

    assert_equal "error", report[:status]
    assert_equal [ "cache" ], report[:failed]
    assert_match(/NullStore/, report[:checks][:cache][:error])
    # The point of the endpoint: the failure is named, and the healthy
    # components are still reported healthy.
    assert_equal "ok", report[:checks][:database][:status]
  end

  # The dead-Redis case that `/up` and a bare `Rails.cache.write` both miss:
  # :redis_cache_store swallows the connection error, so write and read simply
  # return nil and the store looks fine unless you read the value back.
  test "a cache that silently drops writes is an error" do
    Rails.cache.stubs(:write).returns(nil)
    Rails.cache.stubs(:read).returns(nil)

    report = DeepHealthCheck.new.call

    assert_equal "error", report[:status]
    assert_equal [ "cache" ], report[:failed]
    assert_match(/did not return the value it just wrote/, report[:checks][:cache][:error])
  end

  test "a database that cannot answer is an error, and the probe still responds" do
    ActiveRecord::Base.connection.stubs(:select_value).raises(ActiveRecord::StatementInvalid, "connection refused")

    report = DeepHealthCheck.new.call

    assert_equal "error", report[:status]
    assert_equal [ "database" ], report[:failed]
    assert_match(/ActiveRecord::StatementInvalid/, report[:checks][:database][:error])
    assert_match(/connection refused/, report[:checks][:database][:error])
  end

  test "a database that answers SELECT 1 with the wrong value is an error" do
    ActiveRecord::Base.connection.stubs(:select_value).returns(0)

    report = DeepHealthCheck.new.call

    assert_equal [ "database" ], report[:failed]
    assert_match(/answered SELECT 1/, report[:checks][:database][:error])
  end

  # This endpoint is unauthenticated, and a connection error is the likeliest
  # place for a URL carrying a password to surface.
  test "credentials in a backing service's error message are redacted" do
    ENV["REDIS_URL"] = "redis://default:hunter2@redis.internal:6379"
    Redis.stubs(:new).raises(RuntimeError, "Error connecting to redis://default:hunter2@redis.internal:6379")

    report = DeepHealthCheck.new.call

    assert_equal [ "redis" ], report[:failed]
    error = report[:checks][:redis][:error]
    refute_match(/hunter2/, error)
    assert_match(/\[redacted\]@redis\.internal/, error)
  end

  test "an unreachable Redis at REDIS_URL is an error" do
    ENV["REDIS_URL"] = "redis://localhost:6399"
    Redis.stubs(:new).returns(FakeRedis.new(raising: RuntimeError.new("Connection refused")))

    report = DeepHealthCheck.new.call

    assert_equal "error", report[:status]
    assert_equal [ "redis" ], report[:failed]
    assert_match(/Connection refused/, report[:checks][:redis][:error])
  end

  test "a reachable Redis at REDIS_URL is ok" do
    ENV["REDIS_URL"] = "redis://localhost:6379"
    Redis.stubs(:new).returns(FakeRedis.new)

    report = DeepHealthCheck.new.call

    assert_equal "ok", report[:checks][:redis][:status]
    assert_equal "REDIS_URL", report[:checks][:redis][:via]
  end

  # The connection the app actually holds, not a fresh one built from an env var
  # that may point somewhere else.
  test "Redis is pinged through the cache store when the cache store is Redis" do
    store = ActiveSupport::Cache::RedisCacheStore.new(url: "redis://localhost:6379")
    store.stubs(:redis).returns(FakeRedis.new)
    # No server behind the store, so the cache round trip below fails -- which is
    # the point being made: the two checks are independent, and PING is answered
    # by the connection the store holds rather than by anything in REDIS_URL.
    store.stubs(:write).returns(true)
    store.stubs(:read).returns(nil)
    Rails.cache = store
    # Set to a DIFFERENT server, to prove the check does not fall back to it.
    ENV["REDIS_URL"] = "redis://elsewhere.invalid:6379"

    report = DeepHealthCheck.new.call

    assert_equal "ok", report[:checks][:redis][:status]
    assert_equal "cache store", report[:checks][:redis][:via]
    assert_equal [ "cache" ], report[:failed]
  end

  test "a Redis that answers PING with something other than PONG is an error" do
    ENV["REDIS_URL"] = "redis://localhost:6379"
    Redis.stubs(:new).returns(FakeRedis.new(reply: "LOADING"))

    report = DeepHealthCheck.new.call

    assert_equal [ "redis" ], report[:failed]
    assert_match(/LOADING/, report[:checks][:redis][:error])
  end

  test "every failing component is named, not just the first" do
    Rails.cache = ActiveSupport::Cache::NullStore.new
    ActiveRecord::Base.connection.stubs(:select_value).raises(ActiveRecord::StatementInvalid, "boom")

    report = DeepHealthCheck.new.call

    assert_equal [ "database", "cache" ], report[:failed]
  end
end
