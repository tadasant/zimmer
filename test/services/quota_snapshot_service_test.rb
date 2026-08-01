# frozen_string_literal: true

require "test_helper"

class QuotaSnapshotServiceTest < ActiveSupport::TestCase
  test "save_snapshot creates a snapshot from a QuotaCheckService::Result" do
    account = claude_accounts(:primary)
    result = QuotaCheckService::Result.new(
      success: true,
      subscription_type: "claude_max",
      rate_limit_tier: "tier_4",
      utilization_5h: 0.65,
      utilization_7d: 0.42,
      status_5h: "allowed",
      status_7d: "allowed",
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now,
      overage_status: "enabled",
      overage_disabled_reason: nil
    )

    assert_difference -> { account.quota_snapshots.count }, 1 do
      snapshot = QuotaSnapshotService.save_snapshot(account, result, trigger: "test")
      assert_equal "claude_max", snapshot.subscription_type
      assert_equal "tier_4", snapshot.rate_limit_tier
      assert_in_delta 0.65, snapshot.utilization_5h, 0.001
      assert_in_delta 0.42, snapshot.utilization_7d, 0.001
      assert_equal "allowed", snapshot.status_5h
      assert_equal "allowed", snapshot.status_7d
      assert_equal "test", snapshot.trigger
      assert_equal "enabled", snapshot.overage_status
    end
  end

  test "save_snapshot handles nil optional fields" do
    account = claude_accounts(:secondary)
    result = QuotaCheckService::Result.new(
      success: true,
      subscription_type: nil,
      rate_limit_tier: nil,
      utilization_5h: 0.1,
      utilization_7d: nil,
      status_5h: "allowed",
      status_7d: nil,
      reset_5h: nil,
      reset_7d: nil,
      overage_status: nil,
      overage_disabled_reason: nil
    )

    snapshot = QuotaSnapshotService.save_snapshot(account, result, trigger: "rotation")
    assert_not_nil snapshot.id
    assert_nil snapshot.subscription_type
    assert_nil snapshot.utilization_7d
  end

  # Ingestion marking (#248): mark_quota_exceeded! used to fire only on the
  # account that was current when a session hit a wall, so an account that filled
  # its weekly window while idle stayed in ClaudeAccount.available.

  test "save_snapshot marks an account quota_exceeded when its weekly window is spent" do
    account = claude_accounts(:secondary)
    hits_before = account.quota_hit_count

    QuotaSnapshotService.save_snapshot(account, spent_week_result, trigger: "page_view")

    account.reload
    assert account.quota_exceeded?
    assert_equal hits_before + 1, account.quota_hit_count
    assert_not_includes ClaudeAccount.available, account
  end

  test "save_snapshot leaves an account active when its weekly window has cleared" do
    account = claude_accounts(:secondary)

    QuotaSnapshotService.save_snapshot(
      account, spent_week_result(reset_7d: 1.minute.ago), trigger: "page_view"
    )

    assert account.reload.active?
  end

  test "save_snapshot does not relabel a needs_reauth account as quota_exceeded" do
    # The two states drive different recoveries — the quota checker restores one,
    # only a human restores the other — so a spent window must not hide dead auth.
    account = claude_accounts(:secondary)
    account.update!(status: :needs_reauth)

    QuotaSnapshotService.save_snapshot(account, spent_week_result, trigger: "scheduled")

    assert account.reload.needs_reauth?
  end

  private

  def spent_week_result(reset_7d: 2.days.from_now)
    QuotaCheckService::Result.new(
      success: true,
      utilization_5h: 0.29, utilization_7d: 1.0,
      status_5h: "allowed", status_7d: "rejected",
      reset_5h: 1.hour.from_now, reset_7d: reset_7d
    )
  end
end
