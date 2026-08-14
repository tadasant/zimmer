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

  test "a rejecting weekly window keeps the account out of the pool across a sweep" do
    account = claude_accounts(:exceeded)
    snapshot = claude_account_quota_snapshots(:exceeded_snapshot)
    snapshot.update!(reset_5h: 1.hour.ago, reset_7d: 2.days.from_now,
      utilization_5h: 0.1, utilization_7d: 0.9, status_7d: "rejected")
    # The fresh probe reports the same shape the stale snapshot did.
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true, utilization_5h: 0.1, utilization_7d: 0.9,
        status_5h: "allowed", status_7d: "rejected",
        reset_5h: 1.hour.from_now, reset_7d: 2.days.from_now
      )
    )

    QuotaResetCheckerJob.perform_now

    assert account.reload.quota_exceeded?
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

  # ===========================================================================
  # Parked-session resumption
  #
  # Restoring accounts was only ever half the job: a session parked by
  # AuthOutageParkService because the pool was empty stayed dormant until its
  # timer-based backstop fired, even though the thing it was waiting for had
  # just happened. The accounts and the sessions blocked on them recover together.
  # ===========================================================================

  test "resumes sessions parked for an auth outage once accounts are restored" do
    parked = create_parked_session

    QuotaResetCheckerJob.perform_now

    parked.reload
    assert_equal "running", parked.status
    assert_nil parked.metadata["auth_outage_reason"]
  end

  # The 2026-07-31 incident: 11 sessions parked auth_unrecoverable against a
  # dead identity, the pool repaired 25 minutes later, and every one of them sat
  # dormant until its ~1h timer because this sweep only ever looked at quota
  # parks. Restoring an account changes the set of identities the runtime can
  # serve, which is the evidence an auth park needs.
  test "resumes sessions parked as auth_unrecoverable once the pool gains a restored account" do
    parked = create_parked_session(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)
    assert claude_accounts(:exceeded).quota_exceeded?

    QuotaResetCheckerJob.perform_now

    assert claude_accounts(:exceeded).reload.active?
    assert_equal "running", parked.reload.status
    assert_nil parked.metadata["auth_outage_reason"]
  end

  # Without that change there is no evidence, and waking would resume the
  # session into the same rejection on every 15-minute tick.
  test "leaves auth_unrecoverable parks asleep when the pool is unchanged" do
    claude_account_quota_snapshots(:exceeded_snapshot)
      .update!(reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now,
        utilization_5h: 1.0, utilization_7d: 1.0)
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, error_message: "Connection refused")
    )
    parked = create_parked_session(reason: AuthOutageParkService::AUTH_UNRECOVERABLE)

    QuotaResetCheckerJob.perform_now

    assert ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).available.exists?,
      "the pool must have an available account, so the decline is the fingerprint guard and not the pool guard"
    assert claude_accounts(:exceeded).reload.quota_exceeded?, "nothing was restored, so no identity changed"
    assert_equal "waiting", parked.reload.status
  end

  test "leaves parked sessions asleep when nothing could be restored" do
    # A pool with exactly one account, still inside its window: nothing to
    # restore, so nothing to wake into.
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.delete_all
    account = ClaudeAccount.create!(
      email: "exhausted@example.com",
      status: :quota_exceeded,
      runtime: "claude_code",
      oauth_config: { "credentials_json" => { "claudeAiOauth" => {} } }
    )
    account.quota_snapshots.create!(
      reset_5h: 2.hours.from_now, reset_7d: 2.hours.from_now,
      utilization_5h: 1.0, utilization_7d: 1.0
    )
    parked = create_parked_session

    QuotaResetCheckerJob.perform_now

    assert_equal "waiting", parked.reload.status
  end

  def create_parked_session(reason: AuthOutageParkService::QUOTA_EXHAUSTED)
    session = Session.create!(
      prompt: "Parked by an auth outage",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    )
    AuthOutageParkService.new(session).park!(reason: reason)
    assert_equal "waiting", session.reload.status
    session
  end
end
