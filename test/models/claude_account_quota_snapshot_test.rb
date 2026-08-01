# frozen_string_literal: true

require "test_helper"

class ClaudeAccountQuotaSnapshotTest < ActiveSupport::TestCase
  test "belongs to claude_account" do
    snapshot = claude_account_quota_snapshots(:primary_recent)
    assert_equal claude_accounts(:primary), snapshot.claude_account
  end

  test "validates claude_account presence" do
    snapshot = ClaudeAccountQuotaSnapshot.new(claude_account: nil)
    assert_not snapshot.valid?
    assert_includes snapshot.errors[:claude_account], "must exist"
  end

  test "to_display_hash returns expected keys" do
    snapshot = claude_account_quota_snapshots(:primary_recent)
    display = snapshot.to_display_hash
    assert_kind_of Hash, display
    assert display.key?(:subscription_type)
    assert display.key?(:utilization_5h)
    assert display.key?(:utilization_7d)
  end

  # seven_day_window_spent? — the one definition of "the week is gone", read by
  # /quotas, QuotaSnapshotService, AccountRotationService and QuotaResetCheckerJob.

  test "seven_day_window_spent? is true when the API is rejecting for the week" do
    assert snapshot(status_7d: "rejected", utilization_7d: 0.5, reset_7d: 1.day.from_now).seven_day_window_spent?,
      "a rejecting status outranks a counter that has drifted below the cap"
  end

  test "seven_day_window_spent? is true when the counter reached the cap" do
    assert snapshot(status_7d: "allowed", utilization_7d: 1.0, reset_7d: 1.day.from_now).seven_day_window_spent?
  end

  test "seven_day_window_spent? is false once the window's reset time has passed" do
    assert_not snapshot(status_7d: "rejected", utilization_7d: 1.0, reset_7d: 1.minute.ago).seven_day_window_spent?
  end

  test "seven_day_window_spent? is false for a healthy or merely warning window" do
    assert_not snapshot(status_7d: "allowed", utilization_7d: 0.3, reset_7d: 5.days.from_now).seven_day_window_spent?
    assert_not snapshot(status_7d: "allowed_warning", utilization_7d: 0.82, reset_7d: 2.days.from_now).seven_day_window_spent?
  end

  test "seven_day_window_spent? is false when there is no 7-day data at all" do
    assert_not snapshot(status_7d: nil, utilization_7d: nil, reset_7d: nil).seven_day_window_spent?
  end

  test "seven_day_window_spent? treats an unrecognized status as blocking" do
    assert snapshot(status_7d: "exceeded", utilization_7d: 0.9, reset_7d: 2.days.from_now).seven_day_window_spent?
  end

  test "effective_utilization zeroes a window whose reset has passed" do
    assert_in_delta 0.0, ClaudeAccountQuotaSnapshot.effective_utilization(0.95, 1.hour.ago)
    assert_in_delta 0.95, ClaudeAccountQuotaSnapshot.effective_utilization(0.95, 1.hour.from_now)
    assert_in_delta 0.95, ClaudeAccountQuotaSnapshot.effective_utilization(0.95, nil)
    assert_nil ClaudeAccountQuotaSnapshot.effective_utilization(nil, 1.hour.ago)
  end

  private

  def snapshot(**attributes)
    ClaudeAccountQuotaSnapshot.new(**attributes)
  end
end
