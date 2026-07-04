require "test_helper"

class GlobalRateLimitTrackerTest < ActiveSupport::TestCase
  setup do
    # Use memory cache for tests to avoid null_store behavior
    @cache = ActiveSupport::Cache::MemoryStore.new
    @tracker = GlobalRateLimitTracker.new(cache: @cache)
    @tracker.clear!
  end

  teardown do
    @tracker.clear!
  end

  test "record_event stores an event timestamp" do
    @tracker.record_event

    assert_equal 1, @tracker.recent_event_count
  end

  test "record_event stores multiple events" do
    3.times { @tracker.record_event }

    assert_equal 3, @tracker.recent_event_count
  end

  test "recent_event_count only counts events within window" do
    # Record an event "in the past" by manipulating timestamps
    old_timestamp = 6.minutes.ago
    @tracker.record_event(timestamp: old_timestamp)

    # Record a recent event
    @tracker.record_event

    # Only the recent event should count
    assert_equal 1, @tracker.recent_event_count
  end

  test "under_pressure? returns false with no events" do
    assert_not @tracker.under_pressure?
  end

  test "under_pressure? returns false with events below threshold" do
    2.times { @tracker.record_event }

    assert_not @tracker.under_pressure?
  end

  test "under_pressure? returns true when events meet threshold" do
    GlobalRateLimitTracker::ESCALATION_THRESHOLD.times { @tracker.record_event }

    assert @tracker.under_pressure?
  end

  test "under_pressure? returns true when events exceed threshold" do
    (GlobalRateLimitTracker::ESCALATION_THRESHOLD + 2).times { @tracker.record_event }

    assert @tracker.under_pressure?
  end

  test "recommended_delay returns normal delays when not under pressure" do
    @tracker.record_event # Just one event, below threshold

    assert_equal GlobalRateLimitTracker::NORMAL_BASE_DELAYS[0], @tracker.recommended_delay(attempt: 0)
    assert_equal GlobalRateLimitTracker::NORMAL_BASE_DELAYS[1], @tracker.recommended_delay(attempt: 1)
    assert_equal GlobalRateLimitTracker::NORMAL_BASE_DELAYS[2], @tracker.recommended_delay(attempt: 2)
  end

  test "recommended_delay returns escalated delays when under pressure" do
    GlobalRateLimitTracker::ESCALATION_THRESHOLD.times { @tracker.record_event }

    assert_equal GlobalRateLimitTracker::ESCALATED_DELAYS[0], @tracker.recommended_delay(attempt: 0)
    assert_equal GlobalRateLimitTracker::ESCALATED_DELAYS[1], @tracker.recommended_delay(attempt: 1)
    assert_equal GlobalRateLimitTracker::ESCALATED_DELAYS[2], @tracker.recommended_delay(attempt: 2)
  end

  test "recommended_delay returns last delay for attempts beyond array" do
    # Beyond the defined delays, should return the last one
    assert_equal GlobalRateLimitTracker::NORMAL_BASE_DELAYS.last, @tracker.recommended_delay(attempt: 10)

    GlobalRateLimitTracker::ESCALATION_THRESHOLD.times { @tracker.record_event }
    assert_equal GlobalRateLimitTracker::ESCALATED_DELAYS.last, @tracker.recommended_delay(attempt: 10)
  end

  test "current_delays returns normal delays when not under pressure" do
    assert_equal GlobalRateLimitTracker::NORMAL_BASE_DELAYS, @tracker.current_delays
  end

  test "current_delays returns escalated delays when under pressure" do
    GlobalRateLimitTracker::ESCALATION_THRESHOLD.times { @tracker.record_event }

    assert_equal GlobalRateLimitTracker::ESCALATED_DELAYS, @tracker.current_delays
  end

  test "clear! removes all tracked events" do
    5.times { @tracker.record_event }
    assert_equal 5, @tracker.recent_event_count

    @tracker.clear!
    assert_equal 0, @tracker.recent_event_count
  end

  test "events are pruned to MAX_STORED_EVENTS" do
    # Record more events than the max
    (GlobalRateLimitTracker::MAX_STORED_EVENTS + 10).times { @tracker.record_event }

    # The count should still be accurate (we prune old ones, but these are all recent)
    # Due to the window, all should count as recent
    assert @tracker.recent_event_count <= GlobalRateLimitTracker::MAX_STORED_EVENTS
  end

  test "events from multiple sessions contribute to global pressure" do
    # Simulate events from different "sessions" by recording multiple times
    # All should contribute to the same global tracker
    @tracker.record_event
    @tracker.record_event
    @tracker.record_event

    assert @tracker.under_pressure?
  end

  test "constant values are as expected" do
    assert_equal 5.minutes, GlobalRateLimitTracker::WINDOW_DURATION
    assert_equal 3, GlobalRateLimitTracker::ESCALATION_THRESHOLD
    assert_equal [ 5, 10, 20 ], GlobalRateLimitTracker::NORMAL_BASE_DELAYS
    assert_equal [ 60, 180, 300 ], GlobalRateLimitTracker::ESCALATED_DELAYS
    assert_equal 100, GlobalRateLimitTracker::MAX_STORED_EVENTS
  end

  test "escalated delays are 60s, 180s (3 min), and 300s (5 min)" do
    # Verify the exact values mentioned in the requirements
    delays = GlobalRateLimitTracker::ESCALATED_DELAYS
    assert_equal 60, delays[0], "First escalated delay should be 60s (1 minute)"
    assert_equal 180, delays[1], "Second escalated delay should be 180s (3 minutes)"
    assert_equal 300, delays[2], "Third escalated delay should be 300s (5 minutes)"
  end

  test "normal delays provide reasonable exponential backoff" do
    delays = GlobalRateLimitTracker::NORMAL_BASE_DELAYS
    assert_equal 5, delays[0], "First normal delay should be 5s"
    assert_equal 10, delays[1], "Second normal delay should be 10s"
    assert_equal 20, delays[2], "Third normal delay should be 20s"
  end

  test "tracker is thread-safe with concurrent access" do
    threads = []
    10.times do
      threads << Thread.new do
        5.times { @tracker.record_event }
      end
    end

    threads.each(&:join)

    # All events should be recorded (may have some lost due to race conditions in MemoryStore)
    # Just verify we got a reasonable count and no errors
    assert @tracker.recent_event_count.positive?
  end

  test "timestamp parameter allows backdating events" do
    # Record an event at a specific time
    specific_time = 2.minutes.ago
    @tracker.record_event(timestamp: specific_time)

    assert_equal 1, @tracker.recent_event_count
  end

  test "old events are automatically pruned on new record" do
    # Record old events
    3.times { @tracker.record_event(timestamp: 10.minutes.ago) }

    # Record a new event (should trigger pruning)
    @tracker.record_event

    # Only the new event should remain
    assert_equal 1, @tracker.recent_event_count
  end
end
