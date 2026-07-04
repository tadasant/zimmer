# Mock implementation of GlobalRateLimitTracker for testing
# This allows tests to control rate limit behavior without real cache interactions.
#
# Usage in tests:
#   tracker = MockRateLimitTracker.new
#   tracker.set_under_pressure(true)  # Simulate rate limit pressure
#   tracker.recommended_delay(attempt: 0)  # Returns escalated delay
#
class MockRateLimitTracker
  attr_accessor :record_event_hook
  attr_reader :recorded_events

  def initialize
    @under_pressure = false
    @recorded_events = []
    @custom_delays = nil
  end

  # Set whether the system is under rate limit pressure
  # @param value [Boolean] true to simulate pressure, false for normal operation
  def set_under_pressure(value)
    @under_pressure = value
  end

  # Set custom delays for testing specific delay values
  # @param delays [Array<Integer>] Custom delay values
  def set_custom_delays(delays)
    @custom_delays = delays
  end

  # Record a rate limit event
  # @param timestamp [Time] The time of the event (defaults to now)
  def record_event(timestamp: Time.current)
    @recorded_events << timestamp
    record_event_hook&.call(timestamp)
  end

  # Get the count of recorded events
  # @return [Integer] Number of recorded events
  def recent_event_count
    @recorded_events.size
  end

  # Check if the system is under rate limit pressure
  # @return [Boolean] The configured pressure state
  def under_pressure?
    @under_pressure
  end

  # Get the recommended delay for a given retry attempt
  # @param attempt [Integer] The retry attempt number (0-indexed)
  # @return [Integer] Recommended delay in seconds
  def recommended_delay(attempt:)
    delays = current_delays
    delays[attempt] || delays.last
  end

  # Get the current delays array based on pressure state
  # @return [Array<Integer>] Array of delays in seconds
  def current_delays
    return @custom_delays if @custom_delays

    @under_pressure ? GlobalRateLimitTracker::ESCALATED_DELAYS : GlobalRateLimitTracker::NORMAL_BASE_DELAYS
  end

  # Clear all recorded events
  def clear!
    @recorded_events.clear
    @under_pressure = false
    @custom_delays = nil
  end
end
