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
    assert_includes attempt.errors[:claude_account], "must exist"
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

  test "deleting the account destroys its login attempts" do
    account = ClaudeAccount.create!(
      email: "login-attempt-destroy@example.com", runtime: "claude_code",
      status: :active, is_current: false, priority: 99
    )
    account.runtime_login_attempts.create!(runtime: "claude_code")
    assert_difference "RuntimeLoginAttempt.count", -1 do
      account.destroy
    end
  end
end
