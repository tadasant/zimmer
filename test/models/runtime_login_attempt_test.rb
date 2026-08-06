# frozen_string_literal: true

require "test_helper"

class RuntimeLoginAttemptTest < ActiveSupport::TestCase
  setup do
    @account = claude_accounts(:primary)
  end

  test "sets defaults on create: starting status and a TTL'd expires_at" do
    freeze_time do
      attempt = @account.runtime_login_attempts.create!(runtime: "claude_code")
      assert_equal "starting", attempt.status
      assert_in_delta (Time.current + RuntimeLoginAttempt::DEFAULT_TTL).to_f,
        attempt.expires_at.to_f, 1.0
    end
  end

  test "explicit status and expires_at are not overwritten" do
    at = 3.minutes.from_now
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "awaiting_user", expires_at: at
    )
    assert_equal "awaiting_user", attempt.status
    assert_in_delta at.to_f, attempt.expires_at.to_f, 1.0
  end

  test "requires a runtime in the known runtimes" do
    attempt = @account.runtime_login_attempts.build(runtime: nil)
    assert_not attempt.valid?
    assert_includes attempt.errors[:runtime], "can't be blank"

    attempt.runtime = "aider"
    assert_not attempt.valid?
    assert_includes attempt.errors[:runtime], "is not included in the list"
  end

  test "requires a status in STATUSES" do
    attempt = @account.runtime_login_attempts.build(runtime: "codex", status: "bogus")
    assert_not attempt.valid?
    assert_includes attempt.errors[:status], "is not included in the list"
  end

  test "belongs to a claude_account" do
    attempt = RuntimeLoginAttempt.new(runtime: "codex")
    assert_not attempt.valid?
    assert_includes attempt.errors[:claude_account], "can't be blank"
  end

  test "an existing attempt stays valid once its account is deleted" do
    attempt = @account.runtime_login_attempts.create!(runtime: "claude_code")
    attempt.claude_account = nil

    assert attempt.valid?, "nullifying the owner on delete must not strand an unsaveable row"
  end

  test "active scope excludes terminal statuses" do
    active = @account.runtime_login_attempts.create!(runtime: "claude_code", status: "awaiting_user")
    RuntimeLoginAttempt::TERMINAL_STATUSES.each do |terminal|
      @account.runtime_login_attempts.create!(runtime: "claude_code", status: terminal)
    end
    assert_equal [ active.id ], @account.runtime_login_attempts.active.pluck(:id)
  end

  test "terminal? / succeeded? / canceled? reflect status" do
    a = @account.runtime_login_attempts.create!(runtime: "codex", status: "succeeded")
    assert a.terminal?
    assert a.succeeded?
    assert_not a.canceled?

    c = @account.runtime_login_attempts.create!(runtime: "codex", status: "canceled")
    assert c.terminal?
    assert c.canceled?
    assert_not c.succeeded?

    live = @account.runtime_login_attempts.create!(runtime: "codex", status: "awaiting_user")
    assert_not live.terminal?
  end

  test "expired_window? is true only once past expires_at" do
    future = @account.runtime_login_attempts.create!(runtime: "codex", expires_at: 5.minutes.from_now)
    assert_not future.expired_window?

    past = @account.runtime_login_attempts.create!(runtime: "codex", status: "awaiting_user")
    past.update_column(:expires_at, 1.minute.ago)
    assert past.expired_window?
  end

  test "deleting the account detaches its login attempts without destroying them" do
    account = ClaudeAccount.create!(
      email: "login-attempt-detach@example.com", runtime: "claude_code",
      status: :active, is_current: false, priority: 99
    )
    attempt = account.runtime_login_attempts.create!(runtime: "claude_code")

    assert_no_difference "RuntimeLoginAttempt.count" do
      account.destroy
    end

    assert_nil attempt.reload.claude_account_id
    assert_equal "login-attempt-detach@example.com", attempt.account_email
  end

  # ── heartbeat / orphan detection ──

  test "an attempt whose job stopped stamping its heartbeat is stalled" do
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "completing", expires_at: 10.minutes.from_now,
      heartbeat_at: (RuntimeLoginAttempt::HEARTBEAT_TIMEOUT + 30.seconds).ago
    )

    assert_predicate attempt, :stalled?
    assert_predicate attempt, :orphaned?
  end

  test "a fresh heartbeat is not stalled" do
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "completing", expires_at: 10.minutes.from_now,
      heartbeat_at: 5.seconds.ago
    )

    assert_not attempt.stalled?
    assert_not attempt.orphaned?
  end

  test "a nil heartbeat is not stalled — the job simply has not dequeued yet" do
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "starting", expires_at: 10.minutes.from_now, heartbeat_at: nil
    )

    assert_not attempt.stalled?, "a queued-but-unstarted attempt must not be reaped as a dead worker"
    assert_not attempt.orphaned?
  end

  test "a terminal attempt is never stalled or orphaned" do
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "succeeded", expires_at: 1.hour.ago, heartbeat_at: 1.hour.ago
    )

    assert_not attempt.stalled?
    assert_not attempt.orphaned?
  end

  test "fail_orphaned! fails a stalled attempt, names the cause, and drops the pasted code" do
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "completing", expires_at: 10.minutes.from_now,
      heartbeat_at: 5.minutes.ago, pasted_code: "secret-auth-code"
    )

    assert attempt.fail_orphaned!

    attempt.reload
    assert_equal "failed", attempt.status
    assert_match(/stopped responding/, attempt.error_message)
    assert_nil attempt.pasted_code
  end

  test "fail_orphaned! expires an attempt past its verification window" do
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "awaiting_user", heartbeat_at: 2.seconds.ago
    )
    attempt.update_column(:expires_at, 1.minute.ago)

    assert attempt.fail_orphaned!

    attempt.reload
    assert_equal "expired", attempt.status
    assert_match(/window expired/, attempt.error_message)
  end

  test "fail_orphaned! leaves a healthy in-flight attempt alone" do
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "completing", expires_at: 10.minutes.from_now,
      heartbeat_at: 1.second.ago
    )

    assert_not attempt.fail_orphaned!
    assert_equal "completing", attempt.reload.status
  end

  test "bus_state reads the UI side of the message bus, and nil once the row is gone" do
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "awaiting_code", pasted_code: "pasted-123"
    )

    assert_equal [ "awaiting_code", "pasted-123" ], RuntimeLoginAttempt.bus_state(attempt.id)

    attempt.destroy!
    assert_nil RuntimeLoginAttempt.bus_state(attempt.id)
  end

  # The reason bus_state owns the uncached block: RuntimeLoginJob polls this row
  # from a query-cache scope with identical SQL every tick. A cached read would
  # be answered from the first result forever and never observe the code the web
  # container wrote — the login would hang at awaiting_code. Assert bus_state
  # really hits the database on a repeat read, where a plain read does not.
  test "bus_state bypasses the query cache so cross-process writes are visible" do
    attempt = @account.runtime_login_attempts.create!(
      runtime: "claude_code", status: "awaiting_code"
    )

    RuntimeLoginAttempt.cache do
      # Prime the cache with the exact SELECT each path issues.
      RuntimeLoginAttempt.where(id: attempt.id).pick(:status, :pasted_code)
      RuntimeLoginAttempt.bus_state(attempt.id)

      assert_queries_count(0) do
        RuntimeLoginAttempt.where(id: attempt.id).pick(:status, :pasted_code)
      end
      assert_queries_count(1) do
        RuntimeLoginAttempt.bus_state(attempt.id)
      end
    end
  end
end
