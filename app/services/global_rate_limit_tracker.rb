# frozen_string_literal: true

# Service for tracking global rate limit events across all sessions
#
# This service uses Rails.cache to track SIGTERM events globally and provides
# adaptive backoff delays based on recent rate limit pressure. When many sessions
# are experiencing SIGTERMs (often due to Claude API 529 rate limits), this
# tracker will recommend longer delays to allow the system to recover.
#
# Thread Safety Note:
# The read-modify-write pattern in record_event is NOT atomic. In high-concurrency
# scenarios, some events may be lost due to race conditions. This is acceptable
# for this use case because:
# 1. Exact accuracy isn't critical - we just need a rough indicator of pressure
# 2. Lost events would under-report pressure, leading to shorter delays (safe default)
# 3. The threshold is low enough (3 events) that some lost events won't matter
#
# Cache Store Note:
# For truly global tracking across multiple workers/servers in production,
# use a shared cache store like Redis. With memory_store (development default),
# each worker tracks events independently.
#
# Usage:
#   tracker = GlobalRateLimitTracker.new
#   tracker.record_event  # Record a SIGTERM/rate limit event
#   delay = tracker.recommended_delay(attempt: 1)
#
class GlobalRateLimitTracker
  # Time window for considering events as "recent"
  WINDOW_DURATION = 5.minutes

  # Cache key for storing events
  CACHE_KEY = "global_rate_limit_tracker:events"

  # Maximum events to store (prevents unbounded growth)
  MAX_STORED_EVENTS = 100

  # Thresholds for escalating delays
  # If we have >= this many events in the window, use escalated delays
  ESCALATION_THRESHOLD = 3

  # Base delays (seconds) for normal operation
  NORMAL_BASE_DELAYS = [ 5, 10, 20 ].freeze

  # Escalated delays (seconds) when under rate limit pressure
  # 60s (1 min), 180s (3 min), 300s (5 min)
  ESCALATED_DELAYS = [ 60, 180, 300 ].freeze

  def initialize(cache: Rails.cache)
    @cache = cache
  end

  # Record a rate limit event (SIGTERM, 529 error, etc.)
  # @param timestamp [Time] The time of the event (defaults to now)
  def record_event(timestamp: Time.current)
    events = fetch_events
    events << timestamp.to_f

    # Prune old events and limit size
    cutoff = (Time.current - WINDOW_DURATION).to_f
    events = events.select { |t| t > cutoff }.last(MAX_STORED_EVENTS)

    store_events(events)
  end

  # Get the count of events in the recent window
  # @return [Integer] Number of events in the last WINDOW_DURATION
  def recent_event_count
    cutoff = (Time.current - WINDOW_DURATION).to_f
    fetch_events.count { |t| t > cutoff }
  end

  # Check if the system is under rate limit pressure
  # @return [Boolean] True if recent events exceed the threshold
  def under_pressure?
    recent_event_count >= ESCALATION_THRESHOLD
  end

  # Get the recommended delay for a given retry attempt
  #
  # Under normal conditions, uses shorter delays (5s, 10s, 20s).
  # Under rate limit pressure, uses longer delays (60s, 180s, 300s).
  #
  # @param attempt [Integer] The retry attempt number (0-indexed)
  # @return [Integer] Recommended delay in seconds
  def recommended_delay(attempt:)
    delays = under_pressure? ? ESCALATED_DELAYS : NORMAL_BASE_DELAYS
    delays[attempt] || delays.last
  end

  # Get the appropriate delays array based on current pressure
  # @return [Array<Integer>] Array of delays in seconds
  def current_delays
    under_pressure? ? ESCALATED_DELAYS : NORMAL_BASE_DELAYS
  end

  # Clear all tracked events (useful for testing)
  def clear!
    @cache.delete(CACHE_KEY)
  end

  private

  def fetch_events
    @cache.read(CACHE_KEY) || []
  end

  def store_events(events)
    # Store with expiration slightly longer than window to ensure cleanup
    @cache.write(CACHE_KEY, events, expires_in: WINDOW_DURATION + 1.minute)
  end
end
