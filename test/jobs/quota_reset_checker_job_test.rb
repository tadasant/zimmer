# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class QuotaResetCheckerJobTest < ActiveSupport::TestCase
  test "restores quota_exceeded account when reset times are past" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)

    # The fixture has reset times in the past already
    assert account.quota_exceeded?
    assert snapshot.reset_5h < Time.current
    assert snapshot.reset_7d < Time.current

    QuotaResetCheckerJob.perform_now

    assert account.reload.active?
  end

  test "does not restore account when reset_5h is in the future and utilization is at 100%" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(reset_5h: 2.hours.from_now, utilization_5h: 1.0)

    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, error_message: "Connection refused")
    )

    QuotaResetCheckerJob.perform_now

    assert account.reload.quota_exceeded?
  end

  test "does not restore account when reset_7d is in the future and utilization is at 100%" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(reset_7d: 2.days.from_now, utilization_7d: 1.0)

    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, error_message: "Connection refused")
    )

    QuotaResetCheckerJob.perform_now

    assert account.reload.quota_exceeded?
  end

  test "skips accounts without snapshots" do
    # Create a quota_exceeded account with no snapshots
    account = ClaudeAccount.create!(
      email: "nosnapshot@example.com",
      status: :quota_exceeded,
      priority: 99
    )

    QuotaResetCheckerJob.perform_now

    assert account.reload.quota_exceeded?
  end

  test "restores when reset times are nil (treated as cleared)" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(reset_5h: nil, reset_7d: nil)

    QuotaResetCheckerJob.perform_now

    assert account.reload.active?
  end

  test "restores account when utilization drops below threshold despite future reset times" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    # Simulate the bug: reset times are in the future but utilization has dropped
    snapshot.update!(
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now,
      utilization_5h: 0.0,
      utilization_7d: 0.72
    )

    QuotaResetCheckerJob.perform_now

    assert account.reload.active?
  end

  test "restores when one window has low utilization and other is high but below 100%" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now,
      utilization_5h: 0.0,
      utilization_7d: 0.95
    )

    QuotaResetCheckerJob.perform_now

    assert account.reload.active?
  end

  test "does not restore when one window has low utilization but other is at 100%" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now,
      utilization_5h: 0.0,
      utilization_7d: 1.0
    )

    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, error_message: "Connection refused")
    )

    QuotaResetCheckerJob.perform_now

    assert account.reload.quota_exceeded?
  end

  test "restores when one window has past reset time and other has low utilization" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(
      reset_5h: 1.hour.ago,
      reset_7d: 5.days.from_now,
      utilization_5h: 0.95,
      utilization_7d: 0.5
    )

    QuotaResetCheckerJob.perform_now

    assert account.reload.active?
  end

  test "window_clear? class method returns true when both windows are below threshold" do
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now,
      utilization_5h: 0.3,
      utilization_7d: 0.5
    )

    assert QuotaResetCheckerJob.window_clear?(snapshot)
  end

  test "window_clear? class method returns true when utilization is high but below 100%" do
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now,
      utilization_5h: 0.95,
      utilization_7d: 0.90
    )

    assert QuotaResetCheckerJob.window_clear?(snapshot)
  end

  test "window_clear? class method returns false when utilization is at 100%" do
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now,
      utilization_5h: 1.0,
      utilization_7d: 1.0
    )

    assert_not QuotaResetCheckerJob.window_clear?(snapshot)
  end

  # Fresh snapshot fetching tests

  test "fetches fresh snapshot via OAuth token and restores account" do
    account = claude_accounts(:exceeded)
    # Stale snapshot with 100% utilization (would not restore without fresh check)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now,
      utilization_5h: 1.0,
      utilization_7d: 1.0
    )

    # Fresh API check returns low utilization
    fresh_result = QuotaCheckService::Result.new(
      success: true,
      utilization_5h: 0.1,
      utilization_7d: 0.2,
      status_5h: "allowed",
      status_7d: "allowed",
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now
    )
    QuotaCheckService.stubs(:check_with_token).returns(fresh_result)

    QuotaResetCheckerJob.perform_now

    assert account.reload.active?, "Account should be restored using fresh snapshot data"
    # Should have created a new snapshot with trigger "scheduled"
    latest = account.latest_snapshot
    assert_equal "scheduled", latest.trigger
    assert_in_delta 0.1, latest.utilization_5h
  end

  test "falls back to stale snapshot when API check fails" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    # Stale snapshot with past reset times (would be restored)
    snapshot.update!(reset_5h: 1.hour.ago, reset_7d: 1.day.ago)

    # API check fails
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, error_message: "timeout")
    )

    QuotaResetCheckerJob.perform_now

    # Should still restore based on stale snapshot (reset times are past)
    assert account.reload.active?
  end

  test "does not restore when fresh snapshot shows high utilization" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    # Stale snapshot has past reset times (would be restored without fresh check)
    snapshot.update!(reset_5h: 1.hour.ago, reset_7d: 1.day.ago)

    # Fresh check reveals utilization is still at 100%
    fresh_result = QuotaCheckService::Result.new(
      success: true,
      utilization_5h: 1.0,
      utilization_7d: 1.0,
      status_5h: "exceeded",
      status_7d: "exceeded",
      reset_5h: 4.hours.from_now,
      reset_7d: 6.days.from_now
    )
    QuotaCheckService.stubs(:check_with_token).returns(fresh_result)

    QuotaResetCheckerJob.perform_now

    assert account.reload.quota_exceeded?, "Account should stay exceeded when fresh data shows high utilization"
  end

  test "refreshes expired token before checking quota" do
    account = claude_accounts(:exceeded)
    # Make token expired
    config = account.oauth_config.deep_dup
    config["credentials_json"]["claudeAiOauth"]["expiresAt"] = 1000000000000
    account.update!(oauth_config: config)

    # Stub successful token refresh
    successful_response = Net::HTTPSuccess.new("1.1", "200", "OK")
    successful_response.stubs(:code).returns("200")
    successful_response.stubs(:body).returns({
      access_token: "refreshed-token",
      refresh_token: "new-refresh",
      expires_in: 3600
    }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(successful_response)

    # Fresh quota check with refreshed token shows low utilization
    fresh_result = QuotaCheckService::Result.new(
      success: true,
      utilization_5h: 0.0,
      utilization_7d: 0.3,
      status_5h: "allowed",
      status_7d: "allowed",
      reset_5h: 4.hours.from_now,
      reset_7d: 6.days.from_now
    )
    QuotaCheckService.stubs(:check_with_token).with("refreshed-token").returns(fresh_result)

    QuotaResetCheckerJob.perform_now

    assert account.reload.active?
  end

  test "skips fresh check when token is expired and cannot refresh" do
    account = claude_accounts(:exceeded)
    # Make token expired, remove refresh token
    config = account.oauth_config.deep_dup
    config["credentials_json"]["claudeAiOauth"]["expiresAt"] = 1000000000000
    config["credentials_json"]["claudeAiOauth"].delete("refreshToken")
    account.update!(oauth_config: config)

    # Stale snapshot has past reset times
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(reset_5h: 1.hour.ago, reset_7d: 1.day.ago)

    QuotaResetCheckerJob.perform_now

    # Should still restore from stale snapshot since reset times are past
    assert account.reload.active?
  end
end
