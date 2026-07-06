# frozen_string_literal: true

require "test_helper"

class CleanupRuntimeLoginAttemptsJobTest < ActiveJob::TestCase
  setup do
    @account = ClaudeAccount.create!(
      email: "cleanup-login-attempts@example.com", runtime: "codex",
      status: :needs_reauth, is_current: false, priority: 70, oauth_config: {}
    )
  end

  test "reaps a non-terminal attempt whose verification window has elapsed" do
    attempt = @account.runtime_login_attempts.create!(runtime: "codex", status: "awaiting_user")
    attempt.update_column(:expires_at, 1.minute.ago)

    CleanupRuntimeLoginAttemptsJob.perform_now

    attempt.reload
    assert_equal "failed", attempt.status
    assert_match(/did not complete/, attempt.error_message)
  end

  test "reaps a non-terminal attempt whose recorded PID is dead and nulls the pasted code" do
    # A PID that is essentially guaranteed not to exist.
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "awaiting_code",
      pid: 2_147_483_000, pasted_code: "secret-auth-code", expires_at: 10.minutes.from_now
    )

    CleanupRuntimeLoginAttemptsJob.perform_now

    attempt.reload
    assert_equal "failed", attempt.status
    assert_nil attempt.pasted_code, "credential-adjacent pasted code must be dropped when reaped"
  end

  test "leaves a healthy in-flight attempt untouched" do
    # PID of this very test process — definitely alive — and a future window.
    attempt = @account.runtime_login_attempts.create!(
      runtime: "codex", status: "awaiting_user",
      pid: Process.pid, expires_at: 10.minutes.from_now
    )

    CleanupRuntimeLoginAttemptsJob.perform_now

    assert_equal "awaiting_user", attempt.reload.status
  end

  test "does not reap a still-starting attempt that has not spawned a CLI yet" do
    # No PID and a future window — the CLI just hasn't launched. Absence of a PID
    # must not be read as a dead process.
    attempt = @account.runtime_login_attempts.create!(
      runtime: "codex", status: "starting", pid: nil, expires_at: 10.minutes.from_now
    )

    CleanupRuntimeLoginAttemptsJob.perform_now

    assert_equal "starting", attempt.reload.status
  end

  test "prunes terminal attempts older than the retention window" do
    old = @account.runtime_login_attempts.create!(runtime: "codex", status: "succeeded")
    old.update_column(:created_at, (CleanupRuntimeLoginAttemptsJob::RETENTION + 1.hour).ago)
    recent = @account.runtime_login_attempts.create!(runtime: "codex", status: "failed")

    assert_difference "RuntimeLoginAttempt.count", -1 do
      CleanupRuntimeLoginAttemptsJob.perform_now
    end
    assert_not RuntimeLoginAttempt.exists?(old.id)
    assert RuntimeLoginAttempt.exists?(recent.id)
  end
end
