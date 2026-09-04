# frozen_string_literal: true

require "test_helper"

class CleanupRuntimeLoginAttemptsJobTest < ActiveJob::TestCase
  setup do
    @account = ClaudeAccount.create!(
      email: "cleanup-login-attempts@example.com", runtime: "codex",
      status: :needs_reauth, is_current: false, priority: 70, oauth_config: {}
    )
  end

  # An elapsed verification window is "expired", not "failed" — the same verdict
  # InferenceController#login_status reaches for the same condition. Both route
  # through RuntimeLoginAttempt#fail_orphaned!, so whichever notices first, the
  # user is told the same thing.
  test "reaps a non-terminal attempt whose verification window has elapsed" do
    attempt = @account.runtime_login_attempts.create!(runtime: "codex", status: "awaiting_user")
    attempt.update_column(:expires_at, 1.minute.ago)

    CleanupRuntimeLoginAttemptsJob.perform_now

    attempt.reload
    assert_equal "expired", attempt.status
    assert_match(/window expired/, attempt.error_message)
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

  # The production scenario the PID check cannot catch: the worker was replaced,
  # so the recorded PID is meaningless — here it belongs to a live, unrelated
  # process — and the verification window is still open. Only the heartbeat shows
  # that nothing is driving this login any more.
  test "reaps an attempt whose worker stopped heartbeating even with a live PID and an open window" do
    stray = spawn("/bin/sh", "-c", "sleep 30", out: File::NULL, err: File::NULL)
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "completing", pid: stray,
      pasted_code: "secret-auth-code", expires_at: 10.minutes.from_now,
      heartbeat_at: (RuntimeLoginAttempt::HEARTBEAT_TIMEOUT + 1.minute).ago
    )

    CleanupRuntimeLoginAttemptsJob.perform_now

    attempt.reload
    assert_equal "failed", attempt.status
    assert_match(/stopped responding/, attempt.error_message)
    assert_nil attempt.pasted_code
    assert_not process_alive?(stray), "the orphaned login CLI must be killed too"
  ensure
    kill_and_reap(stray)
  end

  test "leaves an in-flight attempt with a fresh heartbeat untouched" do
    live = spawn("/bin/sh", "-c", "sleep 30", out: File::NULL, err: File::NULL)
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "completing", pid: live,
      expires_at: 10.minutes.from_now, heartbeat_at: 2.seconds.ago
    )

    CleanupRuntimeLoginAttemptsJob.perform_now

    assert_equal "completing", attempt.reload.status
    assert process_alive?(live), "a healthy login's CLI must be left running"
  ensure
    kill_and_reap(live)
  end

  def process_alive?(pid)
    # A TERMed child stays a zombie until reaped, and signal 0 succeeds against a
    # zombie — so reap first, then ask.
    Process.wait(pid, Process::WNOHANG)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
    false
  end

  def kill_and_reap(pid)
    return unless pid
    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # Already gone.
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

  # This reaper is the only thing that resolves a /inference login panel whose worker
  # died, and the only thing that frees the `auth` thread that login pinned. It
  # rides the lane it serves rather than the backlog that lane exists to escape.
  test "runs on the dedicated auth queue (not default)" do
    assert_equal "auth", CleanupRuntimeLoginAttemptsJob.new.queue_name
    assert_includes ConnectionBudget.good_job_queues, "auth:"
  end
end
