# frozen_string_literal: true

require "test_helper"

# CodexRetryStrategy classifies Codex CLI exits for ProcessLifecycleManager.
# Unlike Claude, Codex exits non-zero on a genuine failure (it has no "exit 1
# means paused for input" convention), and `codex exec resume` exits non-zero
# with a "no rollout found ... -32600" stderr when the rollout target is gone.
# These tests pin both behaviors so the failure surfaces instead of being faked
# as a successful, paused turn.
class CodexRetryStrategyTest < ActiveSupport::TestCase
  setup do
    @file_system = MockFileSystemAdapter.new
    @strategy = CodexRetryStrategy.new(
      cli_adapter: nil,
      session: nil,
      file_system: @file_system,
      process_manager: MockProcessManager.new,
      rate_limit_tracker: nil
    )
  end

  # ---------------------------------------------------------------------------
  # normal_completion_exit?
  # ---------------------------------------------------------------------------

  test "normal_completion_exit? is false for exit 1 (Codex treats it as failure)" do
    assert_equal false, @strategy.normal_completion_exit?(MockProcessManager::MockStatus.new(1))
  end

  test "normal_completion_exit? is false for exit 0 (success handled separately)" do
    assert_equal false, @strategy.normal_completion_exit?(MockProcessManager::MockStatus.new(0))
  end

  # ---------------------------------------------------------------------------
  # failed_resume_recovery_needed?
  # ---------------------------------------------------------------------------

  test "failed_resume_recovery_needed? detects the real 'no rollout found' stderr" do
    path = "/clone/codex_stderr.log"
    @file_system.write(
      path,
      "Error: stream error: stream disconnected before completion: no rollout found " \
      "for thread id 0199c0f6-1a2b-7c3d-8e4f-5a6b7c8d9e0f - code -32600\n"
    )

    assert_equal true, @strategy.failed_resume_recovery_needed?(stderr_log_path: path)
  end

  test "failed_resume_recovery_needed? ignores the bare -32600 RPC code (too generic to trigger recovery)" do
    # -32600 ("Invalid Request") is generic and an MCP server can emit it during a
    # normal turn. Recovery keys on "no rollout found" only, so a bare -32600 must
    # fall through to ordinary failure handling rather than looping fresh starts.
    path = "/clone/codex_stderr.log"
    @file_system.write(path, "Error: request failed - code -32600\n")

    assert_equal false, @strategy.failed_resume_recovery_needed?(stderr_log_path: path)
  end

  test "failed_resume_recovery_needed? is false for unrelated stderr" do
    path = "/clone/codex_stderr.log"
    @file_system.write(path, "Error: model produced an invalid tool call\n")

    assert_equal false, @strategy.failed_resume_recovery_needed?(stderr_log_path: path)
  end

  test "failed_resume_recovery_needed? is false when stderr is missing" do
    assert_equal false, @strategy.failed_resume_recovery_needed?(stderr_log_path: "/clone/codex_stderr.log")
  end

  test "failed_resume_recovery_needed? is false when stderr path is nil" do
    assert_equal false, @strategy.failed_resume_recovery_needed?(stderr_log_path: nil)
  end

  test "failed_resume_recovery_needed? is false when stderr is blank" do
    path = "/clone/codex_stderr.log"
    @file_system.write(path, "")

    assert_equal false, @strategy.failed_resume_recovery_needed?(stderr_log_path: path)
  end

  # ---------------------------------------------------------------------------
  # The recorded-turn-error classifiers (#54), against real rollouts
  # ---------------------------------------------------------------------------

  CLONE = "/tmp/zimmer-codex-fixture"

  def codex_strategy
    @session = sessions(:running)
    @session.update!(agent_runtime: "codex")
    @session.merge_metadata!("working_directory" => CLONE)
    CodexRetryStrategy.new(
      cli_adapter: nil,
      session: @session,
      file_system: @file_system,
      process_manager: MockProcessManager.new,
      rate_limit_tracker: nil
    )
  end

  def answers(strategy)
    {
      context_length: strategy.context_length_error?(stderr_log_path: "#{CLONE}/codex_stderr.log"),
      api_error: strategy.api_error_for_retry?(working_dir: CLONE),
      auth: strategy.auth_recovery_needed?(working_dir: CLONE)
    }
  end

  {
    context_window_stream: :context_length,
    context_length_http_400: :context_length,
    server_500: :api_error,
    overloaded_503: :api_error,
    rate_429: :api_error,
    server_overloaded_stream: :api_error,
    usage_limit_with_windows: :api_error,
    quota_stream: :api_error,
    refresh_token_reused: :auth,
    refresh_token_expired: :auth,
    unauthorized_after_refresh: :auth
  }.each do |fixture, route|
    test "routes the real #{fixture} exit to exactly one recovery path: #{route}" do
      strategy = codex_strategy
      plant_codex_rollout(@file_system, @session, fixture)

      routed = answers(strategy).select { |_path, yes| yes }.keys
      assert_equal [ route ], routed
    end
  end

  %i[completed context_window_then_compacted bad_request_400].each do |fixture|
    test "claims no recovery path for the real #{fixture} rollout" do
      strategy = codex_strategy
      plant_codex_rollout(@file_system, @session, fixture)

      assert_equal({ context_length: false, api_error: false, auth: false }, answers(strategy))
    end
  end

  test "claims nothing once a recovery path has acted on that turn's error" do
    strategy = codex_strategy
    plant_codex_rollout(@file_system, @session, :server_500)
    error = CodexTurnError.terminal(codex_rollout(:server_500))
    @session.merge_metadata!(RecordedTurnError.handled_attributes(error))

    assert_not strategy.api_error_for_retry?(working_dir: CLONE)
  end

  test "claims a NEW failed turn after an earlier one was handled" do
    strategy = codex_strategy
    path = plant_codex_rollout(@file_system, @session, :server_500)
    @session.merge_metadata!(RecordedTurnError.handled_attributes(CodexTurnError.terminal(codex_rollout(:server_500))))
    append_codex_rollout(@file_system, path, :usage_limit_with_windows)

    assert strategy.api_error_for_retry?(working_dir: CLONE)
  end

  test "claims nothing when no rollout can be found" do
    strategy = codex_strategy
    assert_equal({ context_length: false, api_error: false, auth: false }, answers(strategy))
  end

  test "does not read stderr for these classifiers: Codex logs recovered retries there" do
    strategy = codex_strategy
    plant_codex_rollout(@file_system, @session, :completed)
    @file_system.write("#{CLONE}/codex_stderr.log",
      "WARN codex_core::responses_retry: stream disconnected - retrying sampling request (2/5) " \
      "sampling_error=unexpected status 401 Unauthorized: Provided authentication token is expired.\n")

    assert_equal({ context_length: false, api_error: false, auth: false }, answers(strategy))
  end

  test "unclassified_error_text carries Codex's own words for an error nothing claims" do
    strategy = codex_strategy
    plant_codex_rollout(@file_system, @session, :bad_request_400)

    assert_includes strategy.unclassified_error_text(working_dir: CLONE), "invalid_value"
  end

  test "unclassified_error_text is nil for an error a recovery path owns" do
    strategy = codex_strategy
    plant_codex_rollout(@file_system, @session, :server_500)

    assert_nil strategy.unclassified_error_text(working_dir: CLONE)
  end

  test "terminal_api_error names the error the turn died on, handled or not" do
    strategy = codex_strategy
    plant_codex_rollout(@file_system, @session, :server_500)
    error = CodexTurnError.terminal(codex_rollout(:server_500))
    @session.merge_metadata!(RecordedTurnError.handled_attributes(error))

    terminal = strategy.terminal_api_error(working_dir: CLONE)

    assert_equal error.message, terminal.text
    assert terminal.recognized?
    assert_equal error.id, terminal.line
  end

  test "terminal_api_error marks an unclassified error unrecognized, which is what alerts" do
    strategy = codex_strategy
    plant_codex_rollout(@file_system, @session, :bad_request_400)

    assert_not strategy.terminal_api_error(working_dir: CLONE).recognized?
  end

  test "terminal_api_error is nil for a completed turn" do
    strategy = codex_strategy
    plant_codex_rollout(@file_system, @session, :completed)

    assert_nil strategy.terminal_api_error(working_dir: CLONE)
  end

  test "classifies exits, so an exit none of its classifiers claims is alerted on" do
    assert @strategy.classifies_exits?
  end

  test "honors the shared retry-strategy classifier contract" do
    %i[normal_completion_exit? context_length_error? failed_resume_recovery_needed? api_error_for_retry?
       auth_recovery_needed? unclassified_error_text terminal_api_error].each do |method_name|
      assert_respond_to @strategy, method_name
    end
  end

  test "answers nothing without a session, rather than raising" do
    assert_not @strategy.api_error_for_retry?(working_dir: CLONE)
    assert_nil @strategy.terminal_api_error(working_dir: nil)
  end
end
