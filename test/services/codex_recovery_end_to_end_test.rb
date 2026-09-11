# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "tmpdir"

# A Codex session that hits each failure, driven through the same entry point
# production uses — ProcessLifecycleManager#handle_exit, with Codex's real exit
# code (1) and the rollout the real codex-cli 0.146.0 wrote for that failure
# (CodexRolloutFixtures). Without the classification in #54 every one of these
# ends the same way: the session fails, whatever the cause.
#
# What is real here: the retry strategy, the three recovery services, the
# coordinator, CodexAuthProvider's rotation over the fixture Codex pool, the
# quota snapshot, and the park. What is not: the process (MockProcessManager),
# the CLI (MockCodexRuntimeAdapter records the resume it was asked for), the
# network (token validation is stubbed), and wall-clock waits.
class CodexRecoveryEndToEndTest < ActiveJob::TestCase
  CLONE = "/tmp/zimmer-codex-fixture"

  setup do
    # Rotation writes auth.json; keep it out of the real ~/.codex.
    @tmpdir = Dir.mktmpdir
    @original_codex_home = CodexAuthProvider::CODEX_HOME
    @original_auth_json_path = CodexAuthProvider::AUTH_JSON_PATH
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, @tmpdir)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, File.join(@tmpdir, "auth.json"))

    @session = Session.create!(
      prompt: "Codex test prompt",
      agent_runtime: "codex",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      metadata: {
        "clone_path" => CLONE,
        "working_directory" => CLONE,
        AuthRecoveryCoordinator::IDENTITY_KEY => claude_accounts(:codex_primary).email
      },
      transcript: { "type" => "user", "message" => { "content" => "Codex test prompt" } }.to_json
    )

    @file_system = MockFileSystemAdapter.new
    @file_system.mkdir_p(CLONE)
    @process_manager = MockProcessManager.new
    @adapter = MockCodexRuntimeAdapter.new
    @rate_limit_tracker = GlobalRateLimitTracker.new
    @log_buffer = LogBuffer.new(@session)

    # No wall clock: the status confirmations, backoffs and the respawn's
    # five-second liveness bar are all waits, not behaviour.
    [ ProcessLifecycleManager, ApiErrorRetryService, ContextLengthRetryService, AuthRecoveryService ].each do |klass|
      klass.any_instance.stubs(:sleep)
    end
    [ ApiErrorRetryService, ContextLengthRetryService, AuthRecoveryService ].each do |klass|
      klass.any_instance.stubs(:verify_process_running).returns(true)
    end
    # Rotation validates the next account's tokens against OpenAI.
    ClaudeAccount.any_instance.stubs(:refresh_token!).returns(true)
  end

  teardown do
    FileUtils.rm_rf(@tmpdir)
    CodexAuthProvider.send(:remove_const, :CODEX_HOME)
    CodexAuthProvider.const_set(:CODEX_HOME, @original_codex_home)
    CodexAuthProvider.send(:remove_const, :AUTH_JSON_PATH)
    CodexAuthProvider.const_set(:AUTH_JSON_PATH, @original_auth_json_path)
  end

  def manager
    @manager ||= ProcessLifecycleManager.new(
      session: @session,
      cli_adapter: @adapter,
      process_manager: @process_manager,
      log_buffer: @log_buffer,
      file_system: @file_system,
      rate_limit_tracker: @rate_limit_tracker
    )
  end

  # Spawn, let the real rollout for `fixture` land, and exit the way Codex does.
  def codex_turn_fails_with(fixture)
    manager.spawn(prompt: "Hello", working_dir: CLONE)
    @rollout = plant_codex_rollout(@file_system, @session, fixture)
    manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: CLONE)
  end

  def session_log
    @log_buffer.flush
    @session.logs.reload.map(&:content).join("\n")
  end

  # --- transient upstream failures ---------------------------------------------

  test "a 500 is retried with backoff by resuming the same thread" do
    decision = codex_turn_fails_with(:server_500)

    assert_equal :continue, decision.action
    resumed = @adapter.resumed_sessions.last
    assert_equal @session.reload.session_id, resumed[:session_id]
    assert AutomatedPrompts.system_recovery?(resumed[:prompt])
    assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session)
    assert_match(/API server error detected - attempting auto-retry 1\/6/, session_log)
  end

  test "a 429 Codex could not outlast is retried as a rate limit, without pressuring the Claude fleet" do
    @rate_limit_tracker.expects(:record_event).never

    decision = codex_turn_fails_with(:rate_429)

    assert_equal :continue, decision.action
    assert_match(/Rate limit detected - attempting auto-retry 1\/6/, session_log)
  end

  test "a dropped stream or refused connection is retried like a 5xx" do
    decision = codex_turn_fails_with(:stream_disconnected)

    assert_equal :continue, decision.action
    assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session.reload)
  end

  test "the same dead turn is not retried twice, but the next failed turn is" do
    # The dead turn is failed and named, but it is not an unknown failure mode.
    UnclassifiedFailureReporter.expects(:report).never

    codex_turn_fails_with(:server_500)
    assert_equal 1, ApiErrorRetryService::BUDGET.count_for(@session.reload)

    # The resumed process dies before Codex writes anything new: the rollout still
    # ends on the 500 that was already retried, so nothing may claim it again.
    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: CLONE)
    assert_equal :failed, decision.action
    assert_match(/We're currently experiencing high demand/, decision.error_message)
    assert_equal 1, @adapter.resumed_sessions.size

    # Whereas a resumed turn that fails again is a new failure, and is retried.
    @session.update!(status: :running)
    append_codex_rollout(@file_system, @rollout, :overloaded_503)
    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: CLONE)
    assert_equal :continue, decision.action
    assert_equal 2, ApiErrorRetryService::BUDGET.count_for(@session.reload)
  end

  test "a retry budget that is spent fails the session rather than looping" do
    @session.merge_metadata!(ApiErrorRetryService::BUDGET.key => ApiErrorRetryService::BUDGET.max)

    decision = codex_turn_fails_with(:server_500)

    assert_equal :failed, decision.action
    assert_equal "API error retry limit exhausted", decision.error_message
    assert_empty @adapter.resumed_sessions
  end

  # --- quota ---------------------------------------------------------------------

  test "a usage limit rotates to the next Codex account and resumes, keeping the reading that says when the old one is back" do
    decision = codex_turn_fails_with(:usage_limit_with_windows)

    assert_equal :continue, decision.action

    primary = claude_accounts(:codex_primary).reload
    secondary = claude_accounts(:codex_secondary).reload
    assert primary.quota_exceeded?
    assert secondary.is_current?
    assert_equal "codex_account_2", JSON.parse(File.read(CodexAuthProvider::AUTH_JSON_PATH)).dig("tokens", "account_id")
    assert_equal secondary.email, @session.reload.metadata[AuthRecoveryCoordinator::IDENTITY_KEY]

    reading = primary.latest_snapshot
    assert_equal "usage_limit", reading.trigger
    assert_equal Time.zone.at(1789136947), reading.reset_5h

    assert AutomatedPrompts.system_recovery?(@adapter.resumed_sessions.last[:prompt])
    assert_match(/Account quota hit — rotated to #{Regexp.escape(secondary.email)}/, session_log)
  end

  test "a usage limit that came with no windows still rotates, and records a refusal nothing restores on a guess" do
    decision = codex_turn_fails_with(:usage_limit_without_windows)

    assert_equal :continue, decision.action
    primary = claude_accounts(:codex_primary).reload
    assert primary.quota_exceeded?
    assert_equal "rejected", primary.latest_snapshot.status_5h
    assert_not primary.latest_snapshot.windows_clear?
  end

  test "a usage limit with every Codex account spent parks the session until quota resets" do
    ClaudeAccount.for_runtime("codex").where.not(id: claude_accounts(:codex_primary).id)
      .update_all(status: ClaudeAccount.statuses[:quota_exceeded])

    decision = codex_turn_fails_with(:usage_limit_with_windows)

    assert_equal :needs_input, decision.action
    assert_match(/quota limit reached and no other accounts available/i, decision.error_message)
    assert_equal true, @session.reload.metadata["pending_sleep"]
    assert_empty @adapter.resumed_sessions
  end

  # --- context window ----------------------------------------------------------

  test "a context-window failure resumes the thread so Codex compacts it, with no /compact turn" do
    decision = codex_turn_fails_with(:context_window_stream)

    assert_equal :continue, decision.action
    prompt = @adapter.resumed_sessions.last[:prompt]
    assert_not_equal ContextLengthRetryService::COMPACT_PROMPT, prompt
    assert AutomatedPrompts.system_recovery?(prompt)
    assert_nil @session.reload.metadata["pending_compact_continuation"],
      "Codex answers the resume prompt in the compacting turn itself; there is no second turn to owe"
    assert_equal 1, ContextLengthRetryService::BUDGET.count_for(@session)
  end

  test "once Codex compacts and completes, the session comes to rest normally" do
    codex_turn_fails_with(:context_window_stream)
    @file_system.write(@rollout, codex_rollout(:context_window_then_compacted))

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: CLONE)

    assert_equal :needs_input, decision.action
    assert_equal 1, @adapter.resumed_sessions.size, "no further respawn after the compacted turn completed"
  end

  test "an HTTP 400 context_length_exceeded is the same compaction" do
    assert_equal :continue, codex_turn_fails_with(:context_length_http_400).action
    assert AutomatedPrompts.system_recovery?(@adapter.resumed_sessions.last[:prompt])
  end

  # --- auth ----------------------------------------------------------------------

  test "a refresh token another refresher spent is re-seeded once, not rotated away from" do
    CodexAuthProvider.any_instance.stubs(:refresh!).returns(RuntimeAuthProvider::Result.new(ok: true, error: nil))

    decision = codex_turn_fails_with(:refresh_token_reused)

    assert_equal :continue, decision.action
    assert claude_accounts(:codex_primary).reload.is_current?, "a healthy account must not be rotated away from"
    assert_equal 0, AccountRotationEvent.where(runtime: "codex").count
    assert_match(/re-seeded them/, session_log)
  end

  test "the re-seed is spent once per incident: failing the same way again rotates" do
    CodexAuthProvider.any_instance.stubs(:refresh!).returns(RuntimeAuthProvider::Result.new(ok: true, error: nil))
    codex_turn_fails_with(:refresh_token_reused)

    append_codex_rollout(@file_system, @rollout, :unauthorized_after_refresh)
    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: CLONE)

    assert_equal :continue, decision.action
    assert claude_accounts(:codex_secondary).reload.is_current?
    assert_equal "auth_recovery", AccountRotationEvent.where(runtime: "codex").last.reason
    assert claude_accounts(:codex_primary).reload.active?,
      "an auth rotation is not quota evidence, so the outgoing account stays in the pool"
  end

  test "an API-key account the backend rejects is rotated away from, not re-seeded" do
    claude_accounts(:codex_primary).update_columns(is_current: false)
    claude_accounts(:codex_api_key).update_columns(is_current: true)
    @session.merge_metadata!(AuthRecoveryCoordinator::IDENTITY_KEY => claude_accounts(:codex_api_key).email)

    decision = codex_turn_fails_with(:unauthorized_after_refresh)

    assert_equal :continue, decision.action
    assert_not claude_accounts(:codex_api_key).reload.is_current?
    assert_equal "auth_recovery", AccountRotationEvent.where(runtime: "codex").last.reason
  end

  test "a refresh token that is dead rotates to the next account" do
    CodexAuthProvider.any_instance.stubs(:refresh!).returns(RuntimeAuthProvider::Result.new(ok: false, error: :needs_reauth))

    decision = codex_turn_fails_with(:refresh_token_expired)

    assert_equal :continue, decision.action
    assert claude_accounts(:codex_secondary).reload.is_current?
    assert_equal "auth_recovery", AccountRotationEvent.where(runtime: "codex").last.reason
  end

  # --- what is still a failure -------------------------------------------------

  test "an error no recovery path owns fails the session and pages with Codex's own words" do
    UnclassifiedFailureReporter.expects(:report).with do |kind:, output:, **|
      kind == "terminal API error" && output.to_s.include?("invalid_value")
    end

    decision = codex_turn_fails_with(:bad_request_400)

    assert_equal :failed, decision.action
    assert_empty @adapter.resumed_sessions
  end

  test "a failed resume is still a fresh start, ahead of any recorded error" do
    manager.spawn(prompt: "Hello", working_dir: CLONE)
    plant_codex_rollout(@file_system, @session, :server_500)
    @file_system.write("#{CLONE}/codex_stderr.log", "Error: no rollout found for thread id x - code -32600\n")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: CLONE)

    assert_equal :continue, decision.action
    assert_equal 2, @adapter.executed_commands.size
    assert_empty @adapter.resumed_sessions
  end
end
