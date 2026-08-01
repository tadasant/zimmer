# frozen_string_literal: true

require "digest"

# The one cooldown in front of Zimmer's destructive health maintenance actions
# — cleanup_processes, retry_sessions, archive_old — shared by all three surfaces
# that can run them: HealthController (the web dashboard), Api::V1::HealthController,
# and the native MCP server's `action_health` tool. All three build their keys
# here, so a caller cannot get a second run out of one cooldown by switching
# surfaces. That used to be a comment and three copies of the same three methods;
# it is now one object.
#
# Two properties worth stating outright, because both were once wrong:
#
# **The bucket is per caller.** A key that named only the action made the
# cooldown a global mutex: one noisy client's cleanup locked every other key
# holder out of maintenance for 30 seconds, which is a denial of service dressed
# up as throttling. The caller component is a digest of the presented API key,
# never the key itself — cache keys get logged, dumped by `redis-cli --scan`,
# and read by anyone debugging the store, which is exactly where a live
# credential must not be. The flip side, stated plainly: the *aggregate* rate of
# destructive actions now scales with the number of valid API keys. That is the
# trade a per-caller limit makes, and with `API_KEYS` holding a handful of
# strings it is the right one.
#
# **It fails closed.** The limiter is only as real as the store behind it, and it
# can be unreal in two ways — only one of which a type check catches:
#
#   * a `:null_store` drops every write and misses every read (the test env);
#   * a **Redis that is down**. `:redis_cache_store` is configured with an
#     `error_handler` that logs the exception and swallows it, so a dead Redis
#     does not raise: `read` returns nil and `write` returns nil. A limiter that
#     only asked `is_a?(NullStore)` would sail straight through that and answer
#     "not limited" forever — silently not limiting, which is worse than not
#     limiting at all, because the cooldown is documented as if it holds.
#
# So `store_usable?` writes a canary and checks what came back, and `limited?`
# reports true when the store cannot enforce anything. Each caller turns that
# into an explicit refusal.
class HealthActionCooldown
  COOLDOWN = 30.seconds
  KEY_PREFIX = "health_api_rate_limit"
  # A request that reached a health action without presenting a key came through
  # a surface that does not require one — today that is the web dashboard, which
  # has no authentication at all. There is nothing to distinguish such callers
  # from each other, so they share one bucket rather than each getting an
  # unthrottled one. Anything that *does* have a key must pass it: a caller that
  # silently defaulted to this bucket would reintroduce the global mutex above.
  ANONYMOUS = "anonymous"
  DIGEST_LENGTH = 32
  PROBE_KEY = "#{KEY_PREFIX}:store_probe"
  PROBE_TTL = 10.seconds

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

  # Memoized per instance, so this costs one extra round trip per request that
  # reaches a rate-limited action — three low-volume maintenance endpoints — and
  # not one per call.
  #
  # Both halves are needed. A NullStore's `write` cheerfully returns true, so the
  # canary alone would not catch it; a broken Redis is not a NullStore, so the
  # type check alone would not catch it either.
  def store_usable?
    return @store_usable if defined?(@store_usable)

    @store_usable = !Rails.cache.is_a?(ActiveSupport::Cache::NullStore) &&
      Rails.cache.write(PROBE_KEY, true, expires_in: PROBE_TTL).present?
  end

  def key(action)
    "#{KEY_PREFIX}:#{action}:#{@fingerprint}"
  end
end
