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
  # Stubbed classifiers (not yet characterized for Codex)
  # ---------------------------------------------------------------------------

  test "context_length_error? defers to generic failure handling (returns false)" do
    assert_equal false, @strategy.context_length_error?(stderr_log_path: "/clone/codex_stderr.log")
  end

  test "api_error_for_retry? defers to generic failure handling (returns false)" do
    assert_equal false, @strategy.api_error_for_retry?(working_dir: "/clone")
  end

  test "honors the shared retry-strategy classifier contract" do
    %i[normal_completion_exit? context_length_error? failed_resume_recovery_needed? api_error_for_retry?].each do |method_name|
      assert_respond_to @strategy, method_name
    end
  end
end
