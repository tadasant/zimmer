# frozen_string_literal: true

require "test_helper"

class QuotasHelperTest < ActionView::TestCase
  include QuotasHelper

  # effective_utilization tests

  test "effective_utilization returns original value when reset_time is nil" do
    assert_in_delta 0.85, effective_utilization(0.85, nil)
  end

  test "effective_utilization returns original value when reset_time is in the future" do
    assert_in_delta 0.85, effective_utilization(0.85, 2.hours.from_now)
  end

  test "effective_utilization returns 0.0 when reset_time has passed" do
    assert_in_delta 0.0, effective_utilization(0.95, 1.hour.ago)
  end

  test "effective_utilization returns 0.0 when reset_time is exactly now" do
    assert_in_delta 0.0, effective_utilization(0.95, Time.current)
  end

  test "effective_utilization returns nil when utilization is nil regardless of reset_time" do
    assert_nil effective_utilization(nil, 1.hour.ago)
  end

  # seven_day_window_spent? tests

  test "seven_day_window_spent? is true when the 7-day status is rejecting" do
    assert seven_day_window_spent?(snapshot(utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now))
  end

  test "seven_day_window_spent? is true when the 7-day counter reached the cap" do
    assert seven_day_window_spent?(snapshot(utilization_7d: 1.0, status_7d: "allowed", reset_7d: 1.day.from_now))
  end

  test "seven_day_window_spent? is false for a healthy 7-day window" do
    assert_not seven_day_window_spent?(snapshot(utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now))
  end

  test "seven_day_window_spent? is false once the rejecting window has reset" do
    assert_not seven_day_window_spent?(snapshot(utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.minute.ago))
  end

  test "seven_day_window_spent? is false when there is no 7-day data" do
    assert_not seven_day_window_spent?(snapshot(utilization_7d: nil, status_7d: nil, reset_7d: nil))
  end

  test "seven_day_window_spent? is false for a nil snapshot" do
    assert_not seven_day_window_spent?(nil)
  end

  test "seven_day_window_spent? is false for allowed_warning, which still serves" do
    # Anthropic's third status value. Reading it as blocking would invent
    # exhaustion for an account that is merely approaching its cap.
    assert_not seven_day_window_spent?(snapshot(utilization_7d: 0.82, status_7d: "allowed_warning", reset_7d: 2.days.from_now))
  end

  test "seven_day_window_spent? treats an unrecognized status as blocking" do
    assert seven_day_window_spent?(snapshot(utilization_7d: 0.9, status_7d: "exceeded", reset_7d: 2.days.from_now))
  end

  test "seven_day_window_spent? is true for a rejecting window with no reset time" do
    assert seven_day_window_spent?(snapshot(utilization_7d: 1.0, status_7d: "rejected", reset_7d: nil))
  end

  # pool_utilization_5h tests
  #
  # The motivating case: an account reporting plenty of 5-hour headroom while
  # its 7-day window turns every request away. The headroom is fictional, so
  # the pool must see the account as fully utilized.

  test "pool_utilization_5h counts a 7d-rejected account as fully utilized despite a low 5h counter" do
    snap = snapshot(
      utilization_5h: 0.29, status_5h: "allowed", reset_5h: 72.minutes.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now
    )

    assert_in_delta 1.0, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h returns the raw 5h value when both windows are healthy" do
    snap = snapshot(
      utilization_5h: 0.45, status_5h: "allowed", reset_5h: 3.hours.from_now,
      utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now
    )

    assert_in_delta 0.45, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h leaves a merely high 7d window alone" do
    snap = snapshot(
      utilization_5h: 0.10, status_5h: "allowed", reset_5h: 3.hours.from_now,
      utilization_7d: 0.95, status_7d: "allowed", reset_7d: 5.days.from_now
    )

    assert_in_delta 0.10, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h leaves an allowed_warning 7d window alone" do
    snap = snapshot(
      utilization_5h: 0.15, status_5h: "allowed", reset_5h: 3.hours.from_now,
      utilization_7d: 0.82, status_7d: "allowed_warning", reset_7d: 2.days.from_now
    )

    assert_in_delta 0.15, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h drops back to the 5h value once the 7d window resets" do
    snap = snapshot(
      utilization_5h: 0.29, status_5h: "allowed", reset_5h: 1.hour.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.minute.ago
    )

    assert_in_delta 0.29, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h honors a reset 5h window when the 7d window is healthy" do
    snap = snapshot(
      utilization_5h: 0.95, status_5h: "allowed", reset_5h: 1.minute.ago,
      utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now
    )

    assert_in_delta 0.0, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h reports a 7d-blocked account with no 5h data as fully utilized" do
    snap = snapshot(
      utilization_5h: nil, status_5h: nil, reset_5h: nil,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now
    )

    assert_in_delta 1.0, pool_utilization_5h(snap)
  end

  test "pool_utilization_5h returns nil without a snapshot" do
    assert_nil pool_utilization_5h(nil)
  end

  # five_hour_headroom_unusable? tests

  test "five_hour_headroom_unusable? is true when a 7d-spent account still shows 5h headroom" do
    assert five_hour_headroom_unusable?(snapshot(
      utilization_5h: 0.29, status_5h: "allowed", reset_5h: 72.minutes.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now
    ))
  end

  test "five_hour_headroom_unusable? is false when the 5h window is spent too" do
    assert_not five_hour_headroom_unusable?(snapshot(
      utilization_5h: 1.0, status_5h: "rejected", reset_5h: 1.hour.from_now,
      utilization_7d: 1.0, status_7d: "rejected", reset_7d: 1.day.from_now
    ))
  end

  test "five_hour_headroom_unusable? is false for a nil snapshot" do
    assert_not five_hour_headroom_unusable?(nil)
  end

  test "five_hour_headroom_unusable? is false when the 7d window is healthy" do
    assert_not five_hour_headroom_unusable?(snapshot(
      utilization_5h: 0.29, status_5h: "allowed", reset_5h: 72.minutes.from_now,
      utilization_7d: 0.30, status_7d: "allowed", reset_7d: 5.days.from_now
    ))
  end

  # time_until_reset tests

  test "time_until_reset returns N/A for nil" do
    assert_equal "N/A", time_until_reset(nil)
  end

  test "time_until_reset returns Window reset when time has passed" do
    assert_equal "Window reset", time_until_reset(1.hour.ago)
  end

  test "time_until_reset returns formatted time for future reset" do
    result = time_until_reset(3.hours.from_now)
    assert_match(/2h/, result)
    assert_match(/m/, result)
  end

  # The reported bug: minutes are the finest unit, so the last minute before a
  # reset had no whole unit to report and joined to "". The card interpolates
  # this after a label, so the page rendered "Resets in" and nothing else.
  test "time_until_reset names the sub-minute window instead of returning blank" do
    assert_equal "< 1m", time_until_reset(30.seconds.from_now)
  end

  test "time_until_reset names the sub-minute window one second before reset" do
    assert_equal "< 1m", time_until_reset(1.second.from_now)
  end

  test "time_until_reset switches to whole minutes at exactly one minute" do
    assert_equal "1m", time_until_reset(1.minute.from_now)
  end

  # The guarantee the view depends on: no reset time, at any distance, may
  # render as blank or whitespace after the "Resets in" label. Walks the whole
  # range rather than the boundaries alone, because the empty join came from a
  # combination of components rather than from one special-cased input.
  test "time_until_reset never renders blank for any offset" do
    offsets = [ 0.5, 1, 30, 59, 59.9, 60, 61, 90, 3599, 3600, 3601, 86_399, 86_400,
               86_430, 90_000, 7.days.to_i, 30.days.to_i ]

    offsets.each do |seconds|
      result = time_until_reset(Time.current + seconds)
      assert_predicate result.strip, :present?, "time_until_reset rendered blank for +#{seconds}s"
    end
  end

  # window_status_badge tests
  #
  # A status describes the window that was open when the reading was taken.
  # After that window's reset time the card corrects the counter to 0.0% and
  # prints "Window reset" — a red "Rejected" badge left beside them contradicts
  # both, and outlives the window it described.

  test "window_status_badge renders the status while the window is still open" do
    assert_match(/Rejected/, window_status_badge("rejected", 1.day.from_now))
  end

  test "window_status_badge renders the status when there is no reset time" do
    assert_match(/Allowed/, window_status_badge("allowed", nil))
  end

  test "window_status_badge drops a status whose window has already reset" do
    assert_nil window_status_badge("rejected", 1.hour.ago)
  end

  test "window_status_badge drops a status whose window resets exactly now" do
    assert_nil window_status_badge("rejected", Time.current)
  end

  # reset_window_line tests

  test "reset_window_line renders nothing without a reset time" do
    assert_nil reset_window_line(nil)
  end

  test "reset_window_line reports a window that has already reset" do
    line = reset_window_line(1.hour.ago)
    assert_match(/Window reset/, line)
    assert_match(/text-green-500/, line)
  end

  test "reset_window_line counts down to a window still open" do
    line = reset_window_line(3.hours.from_now)
    assert_match(/Resets in 2h/, line)
    assert_match(/text-gray-400/, line)
  end

  test "reset_window_line carries a value in the last minute before a reset" do
    assert_match(/Resets in &lt; 1m/, reset_window_line(30.seconds.from_now))
  end

  # utilization_percentage_text tests

  test "utilization_percentage_text shows 0.0% for zero" do
    assert_equal "0.0%", utilization_percentage_text(0.0)
  end

  test "utilization_percentage_text shows N/A for nil" do
    assert_equal "N/A", utilization_percentage_text(nil)
  end

  private

  def snapshot(**attributes)
    ClaudeAccountQuotaSnapshot.new(**attributes)
  end
end
