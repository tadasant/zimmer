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
