# frozen_string_literal: true

require "test_helper"

class ClaudeAccountQuotaSnapshotTest < ActiveSupport::TestCase
  test "belongs to claude_account" do
    snapshot = claude_account_quota_snapshots(:primary_recent)
    assert_equal claude_accounts(:primary), snapshot.claude_account
  end

  test "validates claude_account presence on create" do
    snapshot = ClaudeAccountQuotaSnapshot.new(claude_account: nil)
    assert_not snapshot.valid?
    assert_includes snapshot.errors[:claude_account], "can't be blank"
  end

  test "an existing snapshot stays valid once its account is deleted" do
    # Nullifying the owner on delete is how history survives — it must not leave
    # a row that can never be saved again.
    snapshot = claude_account_quota_snapshots(:primary_recent)
    snapshot.claude_account = nil
    assert snapshot.valid?
  end

  test "captures the account identity at write time" do
    account = claude_accounts(:secondary)
    snapshot = account.quota_snapshots.create!(trigger: "page_view")

    assert_equal account.email, snapshot.account_email
    assert_equal account.runtime, snapshot.account_runtime
  end

  test "attached excludes snapshots whose account was deleted" do
    snapshot = claude_accounts(:secondary).quota_snapshots.create!(trigger: "page_view")
    snapshot.update_column(:claude_account_id, nil)

    assert_not_includes ClaudeAccountQuotaSnapshot.attached, snapshot
    assert_includes ClaudeAccountQuotaSnapshot.attached, claude_account_quota_snapshots(:primary_recent)
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

  # windows_clear? — the counterpart definition: what QuotaResetCheckerJob
  # restores on, what QuotasController heals on, and what the account-level
  # status badge presents.

  test "windows_clear? is true when both counters are below the cap" do
    assert snapshot(reset_5h: 3.hours.from_now, utilization_5h: 0.3,
      reset_7d: 5.days.from_now, utilization_7d: 0.5, status_7d: "allowed").windows_clear?
  end

  test "windows_clear? is true when utilization is high but below 100%" do
    assert snapshot(reset_5h: 3.hours.from_now, utilization_5h: 0.95,
      reset_7d: 5.days.from_now, utilization_7d: 0.90, status_7d: "allowed").windows_clear?
  end

  test "windows_clear? is false when a counter has reached the cap" do
    assert_not snapshot(reset_5h: 3.hours.from_now, utilization_5h: 1.0,
      reset_7d: 5.days.from_now, utilization_7d: 1.0, status_7d: "allowed").windows_clear?
  end

  test "windows_clear? is true once a window's reset time has passed" do
    assert snapshot(reset_5h: 1.minute.ago, utilization_5h: 1.0,
      reset_7d: 1.minute.ago, utilization_7d: 1.0, status_7d: "allowed").windows_clear?
  end

  test "windows_clear? is true when the reset times are unknown" do
    assert snapshot(reset_5h: nil, utilization_5h: nil, reset_7d: nil, utilization_7d: nil).windows_clear?
  end

  test "windows_clear? is false while the API is still rejecting for the week" do
    # The healer, the marker and the badge must read the same evidence. Calling
    # this clear puts the account straight back in front of rotation, which hands
    # it to the next session (#248) — and the marker would exceed it again on the
    # next reading, flipping the account on every sweep.
    assert_not snapshot(reset_5h: 1.hour.ago, utilization_5h: 0.1,
      reset_7d: 2.days.from_now, utilization_7d: 0.9, status_7d: "rejected").windows_clear?
  end

  test "windows_clear? is true once the rejecting weekly window has reset" do
    assert snapshot(reset_5h: 1.hour.ago, utilization_5h: 1.0,
      reset_7d: 1.minute.ago, utilization_7d: 1.0, status_7d: "rejected").windows_clear?
  end

  test "windows_clear? is false while the API is still rejecting on the 5-hour window" do
    # The counter can read as headroom the account cannot spend. Calling this
    # clear would render "Rejected" against the 5-hour window and "Active" for the
    # account on the same card.
    assert_not snapshot(reset_5h: 40.minutes.from_now, utilization_5h: 0.9, status_5h: "rejected",
      reset_7d: 5.days.from_now, utilization_7d: 0.2, status_7d: "allowed").windows_clear?
  end

  test "windows_clear? is true once the rejecting 5-hour window has reset" do
    assert snapshot(reset_5h: 1.minute.ago, utilization_5h: 1.0, status_5h: "rejected",
      reset_7d: 5.days.from_now, utilization_7d: 0.2, status_7d: "allowed").windows_clear?
  end

  test "windows_clear? treats an approaching-cap 5-hour warning as still serving" do
    assert snapshot(reset_5h: 40.minutes.from_now, utilization_5h: 0.9, status_5h: "allowed_warning",
      reset_7d: 5.days.from_now, utilization_7d: 0.2, status_7d: "allowed").windows_clear?
  end

  test "windows_clear? is false when only the 5-hour window is spent" do
    assert_not snapshot(reset_5h: 30.minutes.from_now, utilization_5h: 1.0,
      reset_7d: 5.days.from_now, utilization_7d: 0.2, status_7d: "allowed").windows_clear?
  end

  private

  def snapshot(**attributes)
    ClaudeAccountQuotaSnapshot.new(**attributes)
  end
end
