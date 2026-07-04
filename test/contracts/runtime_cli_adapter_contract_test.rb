# frozen_string_literal: true

require "test_helper"

# Shared contract test for the RuntimeCliAdapter interface.
#
# Every runtime CLI adapter (ClaudeCliAdapter today; CodexRuntimeAdapter in
# #3777) must satisfy the same contract so ProcessLifecycleManager can depend on
# the interface rather than a concrete runtime. MockClaudeCliAdapter participates
# too — the seam only works if the test double honors the same surface.
#
# The suite is parameterized by adapter class so a new runtime gets coverage by
# adding one entry to ADAPTERS. The assertion body lives in
# RuntimeCliAdapterContractAssertions (test/support) so extension-provided
# adapters can reuse it from their own test dir.
class RuntimeCliAdapterContractTest < ActiveSupport::TestCase
  include RuntimeCliAdapterContractAssertions

  # Permanent runtime adapters. Add new permanent runtimes here. Extension-provided
  # adapters (e.g. PtyClaudeCliAdapter, swapped in by the pty_transport extension)
  # are contract-tested from their own extension test dir so the coverage is deleted
  # along with the extension — see test/extensions/pty_transport/.
  ADAPTERS = [ ClaudeCliAdapter, MockClaudeCliAdapter, CodexRuntimeAdapter, MockCodexRuntimeAdapter ].freeze

  ADAPTERS.each do |klass|
    test "#{klass} honors the full runtime CLI adapter contract" do
      assert_runtime_cli_adapter_contract(klass)
    end
  end

  # MockClaudeCliAdapter can be invoked directly (it does not spawn a real
  # process), so verify the return shape of the contract concretely.
  test "MockClaudeCliAdapter#execute returns a pid and stderr_log_path" do
    result = MockClaudeCliAdapter.new.execute(
      prompt: "hello",
      session_id: SecureRandom.uuid,
      working_dir: "/tmp/contract-test"
    )
    assert_kind_of Integer, result[:pid]
    assert_equal File.join("/tmp/contract-test", "claude_stderr.log"), result[:stderr_log_path]
  end

  test "MockClaudeCliAdapter#resume returns a pid and stderr_log_path" do
    result = MockClaudeCliAdapter.new.resume(
      session_id: SecureRandom.uuid,
      working_dir: "/tmp/contract-test"
    )
    assert_kind_of Integer, result[:pid]
    assert_equal File.join("/tmp/contract-test", "claude_stderr.log"), result[:stderr_log_path]
  end

  # MockCodexRuntimeAdapter is likewise invokable directly; verify its return
  # shape and that it tails the Codex (not Claude) stderr log.
  test "MockCodexRuntimeAdapter#execute returns a pid and codex stderr_log_path" do
    result = MockCodexRuntimeAdapter.new.execute(
      prompt: "hello",
      session_id: SecureRandom.uuid,
      working_dir: "/tmp/contract-test"
    )
    assert_kind_of Integer, result[:pid]
    assert_equal File.join("/tmp/contract-test", "codex_stderr.log"), result[:stderr_log_path]
  end

  test "MockCodexRuntimeAdapter#resume returns a pid and codex stderr_log_path" do
    result = MockCodexRuntimeAdapter.new.resume(
      session_id: SecureRandom.uuid,
      working_dir: "/tmp/contract-test"
    )
    assert_kind_of Integer, result[:pid]
    assert_equal File.join("/tmp/contract-test", "codex_stderr.log"), result[:stderr_log_path]
  end
end
