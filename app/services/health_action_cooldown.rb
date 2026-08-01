# frozen_string_literal: true

require "digest"

# The one cooldown in front of Zimmer's destructive health maintenance actions
# — cleanup_processes, retry_sessions, archive_old — shared by the two surfaces
# that can run them: Api::V1::HealthController and the native MCP server's
# `action_health` tool. Both build their keys here, so hammering one surface
# still throttles the other. That used to be a comment and two copies of the
# same three methods; it is now one object.
#
# Two properties worth stating outright, because both were once wrong:
#
# **The bucket is per caller.** A key that named only the action made the
# cooldown a global mutex: one noisy client's cleanup locked every other key
# holder out of maintenance for 30 seconds, which is a denial of service dressed
# up as throttling. The caller component is a digest of the presented API key,
# never the key itself — cache keys get logged, dumped by `redis-cli --scan`,
# and read by anyone debugging the store, which is exactly where a live
# credential must not be.
#
# **It fails closed.** The limiter is only as real as the store behind it. Under
# a null cache store every write is dropped and every read misses, so a naive
# `limited?` answers "no" forever — a limiter that silently does not limit,
# which is worse than none because the cooldown is documented as if it holds.
# `limited?` reports true when the store cannot enforce anything, and each
# caller turns that into an explicit refusal. `Rails.cache` is
# `:redis_cache_store` in development, staging, and production, so this is the
# Redis-is-down path (and the test environment's `:null_store`).
class HealthActionCooldown
  COOLDOWN = 30.seconds
  KEY_PREFIX = "health_api_rate_limit"
  # A request that reached a health action without presenting a key came through
  # a surface that does not require one. There is nothing to distinguish such
  # callers from each other, so they share one bucket rather than each getting
  # an unthrottled one.
  ANONYMOUS = "anonymous"
  DIGEST_LENGTH = 32

  # Truncated because this only has to be stable and collision-free across the
  # handful of strings in ENV["API_KEYS"], not cryptographically binding.
  def self.fingerprint(api_key)
    key = api_key.to_s
    return ANONYMOUS if key.empty?

    Digest::SHA256.hexdigest(key)[0, DIGEST_LENGTH]
  end

  def initialize(fingerprint)
    @fingerprint = fingerprint.presence || ANONYMOUS
  end

  # True when this caller ran `action` less than COOLDOWN ago — or when the
  # store cannot enforce a cooldown at all.
  def limited?(action)
    return true unless store_usable?

    last_run = Rails.cache.read(key(action))
    return false unless last_run

    Time.current - last_run < COOLDOWN
  end

  def record(action)
    return unless store_usable?

    Rails.cache.write(key(action), Time.current, expires_in: COOLDOWN + 1.second)
  end

  def store_usable?
    !Rails.cache.is_a?(ActiveSupport::Cache::NullStore)
  end

  def key(action)
    "#{KEY_PREFIX}:#{action}:#{@fingerprint}"
  end
end
