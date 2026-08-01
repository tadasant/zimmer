# frozen_string_literal: true

require "securerandom"

# The probe behind `GET /up/deep`.
#
# `/up` is `rails/health#show`: it answers 200 as long as the Rails process
# booted and can render a response. That is a real signal, but a narrow one --
# a container with a dead database, an unreachable Redis, or a cache store that
# silently drops every write boots perfectly well and answers `/up` with a green
# 200 while every page in the app 500s. A deploy gate that asks only `/up` is
# therefore a gate that a fully broken deploy walks through, which is how one
# did.
#
# So this touches each backing service the app cannot serve a page without, and
# names the one that failed rather than collapsing everything into a single bit:
#
#   * **database** -- the primary connection answers, AND a real application
#     table is readable. A connection is not a schema: a Postgres that answers
#     `SELECT 1` while the app's tables are absent (wrong database name, an
#     unmigrated volume) is exactly the boots-fine-serves-500s state above.
#   * **cache** -- a canary survives a write/read round trip. `:redis_cache_store`
#     is configured with an `error_handler` that logs and swallows, so a dead
#     Redis does not raise here: `write` and `read` just return nil. Reading the
#     value back is the only way to tell a working store from a store that is
#     quietly discarding everything.
#   * **redis** -- a raw `PING` on the connection the cache store actually holds.
#     Unlike the cache check this one raises rather than being swallowed, so it
#     is what turns "the cache is not storing anything" into "Redis is
#     unreachable, and here is what it said".
#
# **Deliberately not behind `HealthActionCooldown`.** That limiter guards the
# three destructive maintenance actions, and it fails closed -- under a store it
# cannot use it reports *limited*, which would make this endpoint answer "rate
# limited" for precisely the broken-cache case it exists to report. It is also
# the wrong shape: it is a 30-second cooldown, and a health endpoint that
# refuses a monitor's second poll is not a health endpoint. What makes that safe
# to leave unlimited is that the probe is cheap and fixed-cost: one `SELECT 1`,
# one single-row indexed read, one cache round trip, one `PING` -- less work
# than any page the same visitor could request instead.
class DeepHealthCheck
  PROBE_PREFIX = "deep_health_check"
  PROBE_TTL = 30.seconds
  # Seconds. A probe exists to answer quickly or not at all -- an unbounded
  # connect would hang the deploy gate instead of failing it.
  REDIS_TIMEOUT = 2
  MAX_ERROR_LENGTH = 200
  # `scheme://user:password@host` in an exception message. This endpoint is
  # unauthenticated, so what it echoes from a backing service must never be a
  # credential -- and a connection-refused error is the single most likely place
  # for a URL carrying one to surface.
  URL_CREDENTIALS = %r{([a-z][a-z0-9+.\-]*://)[^/\s@]*@}i

  OK = "ok"
  ERROR = "error"
  SKIPPED = "skipped"

  def call
    checks = {
      database: guarded { database_check },
      cache: guarded { cache_check },
      redis: guarded { redis_check }
    }
    failed = checks.select { |_, result| result[:status] == ERROR }.keys

    {
      status: failed.empty? ? OK : ERROR,
      failed: failed.map(&:to_s),
      checks: checks,
      checked_at: Time.current.iso8601
    }
  end

  private

  # Every check reports; none raises. A probe that 500s tells a monitor only
  # that something went wrong, which is the state this whole endpoint exists to
  # improve on.
  def guarded
    yield
  rescue StandardError => e
    error("#{e.class}: #{e.message}")
  end

  def database_check
    value = ActiveRecord::Base.connection.select_value("SELECT 1")
    return error("the primary database answered SELECT 1 with #{value.inspect}") unless value.to_i == 1

    # One indexed row from a real application table, not a count: proof the
    # schema this build expects is actually there, at fixed cost on a table of
    # any size.
    Session.order(:id).limit(1).pluck(:id)

    ok(adapter: ActiveRecord::Base.connection.adapter_name)
  end

  def cache_check
    if Rails.cache.is_a?(ActiveSupport::Cache::NullStore)
      return error("Rails.cache is a NullStore: every write is dropped and every read misses")
    end

    # A key unique to this request. A shared canary key would let two concurrent
    # probes overwrite each other's value and report a working store as broken.
    key = "#{PROBE_PREFIX}:canary:#{SecureRandom.hex(8)}"
    token = SecureRandom.hex(8)

    Rails.cache.write(key, token, expires_in: PROBE_TTL)
    read_back = Rails.cache.read(key)
    Rails.cache.delete(key)

    unless read_back == token
      return error("the cache store did not return the value it just wrote (read back #{read_back.inspect})")
    end

    ok(store: Rails.cache.class.name)
  end

  def redis_check
    client = cache_store_redis

    if client
      reply = with_redis(client) { |conn| conn.ping }
      return error("Redis answered PING with #{reply.inspect}") unless pong?(reply)

      return ok(via: "cache store")
    end

    url = ENV["REDIS_URL"].presence
    # No Redis in this environment is a fact about the environment, not a
    # failure: development and test run a memory store. Reported, not counted
    # against the overall status -- staging and production reach the branch
    # above, where an unreachable Redis is an error.
    return skipped("no Redis is configured (Rails.cache is #{Rails.cache.class.name} and REDIS_URL is unset)") if url.nil?

    reply = Redis.new(url: url, timeout: REDIS_TIMEOUT, connect_timeout: REDIS_TIMEOUT).ping
    return error("Redis answered PING with #{reply.inspect}") unless pong?(reply)

    ok(via: "REDIS_URL")
  end

  # The connection the app actually uses, rather than a fresh one built from an
  # env var: a cache store pointed at the wrong Redis is a failure this must
  # catch, and a side connection to the right one would hide it.
  def cache_store_redis
    return nil unless Rails.cache.is_a?(ActiveSupport::Cache::RedisCacheStore)

    Rails.cache.redis
  end

  # `RedisCacheStore#redis` is a ConnectionPool when one is configured and a
  # bare client otherwise.
  def with_redis(client)
    client.respond_to?(:with) ? client.with { |conn| yield conn } : yield(client)
  end

  def pong?(reply)
    reply.to_s.casecmp("pong").zero?
  end

  def ok(**details)
    { status: OK }.merge(details)
  end

  def skipped(reason)
    { status: SKIPPED, reason: reason }
  end

  def error(message)
    { status: ERROR, error: scrub(message) }
  end

  def scrub(message)
    message.to_s.gsub(URL_CREDENTIALS, '\1[redacted]@').truncate(MAX_ERROR_LENGTH)
  end
end
