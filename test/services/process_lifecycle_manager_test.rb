require "test_helper"
require "mocha/minitest"

class ProcessLifecycleManagerTest < ActiveSupport::TestCase
  setup do
    @session = Session.create!(
      prompt: "Test prompt",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" }
    )

    @mock_process_manager = MockProcessManager.new
    @mock_cli_adapter = MockClaudeCliAdapter.new
    @mock_file_system = MockFileSystemAdapter.new
    # The session's clone directory exists by default — the normal production
    # state. spawn_continuation guards on its presence, so tests exercising the
    # happy continuation path need it registered. Tests that specifically cover a
    # GC'd clone use a different, deliberately-absent working_dir.
    @mock_file_system.mkdir_p("/tmp/test-clone")
    @log_buffer = LogBuffer.new(@session)
  end

  def create_manager
    ProcessLifecycleManager.new(
      session: @session,
      cli_adapter: @mock_cli_adapter,
      process_manager: @mock_process_manager,
      log_buffer: @log_buffer,
      file_system: @mock_file_system
    )
  end

  # ===========================================================================
  # State Machine Tests
  # ===========================================================================

  test "initial state is idle" do
    manager = create_manager
    assert_equal :idle, manager.current_state
  end

  # Regression: MCP elicitation 404s after restart/resume.
  #
  # The constructor — not #spawn — must set zimmer_session_id on the CLI adapter. The
  # resume_monitoring path never calls #spawn, yet a monitored process can exit and
  # route through handle_exit into a respawn (retry service, spawn_continuation, or
  # failed-resume recovery) that reuses this adapter. If the id were set only in
  # #spawn, those respawned MCP servers would inject no ELICITATION_SESSION_ID and
  # their elicitation POSTs would 404 with an empty session-id.
  test "constructor sets zimmer_session_id on the cli adapter so resume-path respawns inject elicitation env" do
    create_manager
    assert_equal @session.id, @mock_cli_adapter.zimmer_session_id
  end

  test "state transitions from idle to running after successful spawn" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    result = manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    assert result.success?
    assert_equal :running, manager.current_state
    assert_equal 12345, manager.current_pid
  end

  test "spawn fails when not in idle state" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "First", working_dir: "/tmp/test")

    # Try to spawn again while running
    result = manager.spawn(prompt: "Second", working_dir: "/tmp/test")

    assert_not result.success?
    assert_match(/Cannot spawn/, result.error)
  end

  test "state returns to idle after spawn failure" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      raise StandardError, "Spawn failed"
    end

    manager = create_manager
    result = manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    assert_not result.success?
    assert_equal :idle, manager.current_state
  end

  test "state transitions to terminated after terminate" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { false }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    result = manager.terminate(reason: :user_pause)

    assert result.success?
    assert_equal :terminated, manager.current_state
    assert_nil manager.current_pid
  end

  # ===========================================================================
  # Spawn Tests
  # ===========================================================================

  test "spawn returns pid and stderr path on success" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    result = manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    assert result.success?
    assert_equal 12345, result.pid
    assert_equal "/tmp/stderr.log", result.stderr_log_path
  end

  test "spawn uses execute for fresh sessions" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test", mcp_config_path: "/tmp/mcp.json")

    assert_equal 1, @mock_cli_adapter.executed_commands.length
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length
    assert_equal "Hello", @mock_cli_adapter.executed_commands.first[:prompt]
    assert_equal "/tmp/mcp.json", @mock_cli_adapter.executed_commands.first[:mcp_config_path]
  end

  test "spawn uses resume for follow-up prompts" do
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Continue please", working_dir: "/tmp/test", resume: true)

    assert_equal 0, @mock_cli_adapter.executed_commands.length
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length
    assert_equal "Continue please", @mock_cli_adapter.resumed_sessions.first[:prompt]
  end

  test "spawn forwards session.auto_compact_window to execute" do
    @session.update!(auto_compact_window: 50_000)
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    assert_equal 50_000, @mock_cli_adapter.executed_commands.first[:auto_compact_window]
  end

  test "spawn forwards session.auto_compact_window to resume" do
    @session.update!(auto_compact_window: 75_000)
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Continue please", working_dir: "/tmp/test", resume: true)

    assert_equal 75_000, @mock_cli_adapter.resumed_sessions.first[:auto_compact_window]
  end

  test "spawn logs on success" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/Process spawned with PID 12345/, log_contents)
  end

  test "spawn logs on failure" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      raise StandardError, "Network error"
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/Failed to spawn process/, log_contents)
    assert_match(/Network error/, log_contents)
  end

  # ===========================================================================
  # Resume Monitoring Tests
  # ===========================================================================

  test "resume_monitoring succeeds when process is running" do
    @mock_process_manager.running_hook = ->(pid) { pid == 54321 }

    manager = create_manager
    result = manager.resume_monitoring(pid: 54321, stderr_log_path: "/tmp/stderr.log")

    assert result.success?
    assert_equal 54321, result.pid
    assert_equal :running, manager.current_state
    assert_equal 54321, manager.current_pid
  end

  test "resume_monitoring fails when process is not running" do
    @mock_process_manager.running_hook = ->(pid) { false }

    manager = create_manager
    result = manager.resume_monitoring(pid: 54321)

    assert_not result.success?
    assert_match(/not running/, result.error)
    assert_equal :idle, manager.current_state
  end

  test "resume_monitoring fails when not in idle state" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    result = manager.resume_monitoring(pid: 54321)

    assert_not result.success?
    assert_match(/Cannot resume monitoring/, result.error)
  end

  # ===========================================================================
  # Terminate Tests
  # ===========================================================================

  test "terminate returns success when no process running" do
    manager = create_manager
    result = manager.terminate(reason: :user_pause)

    assert result.success?
    assert_equal :no_process, result.reason
  end

  test "terminate kills process and clears state" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { false }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    result = manager.terminate(reason: :user_pause)

    assert result.success?
    assert_equal :user_pause, result.reason
    assert_nil manager.current_pid
    assert_equal :terminated, manager.current_state
  end

  test "terminate logs the reason" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { false }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")
    manager.terminate(reason: :follow_up)

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/Terminating process 12345/, log_contents)
    assert_match(/reason: follow_up/, log_contents)
  end

  # ===========================================================================
  # Handle Exit Tests
  # ===========================================================================

  test "handle_exit returns needs_input on successful exit" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Simulate successful exit
    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test")

    assert_equal :needs_input, decision.action
    assert_equal :idle, manager.current_state
  end

  test "handle_exit returns needs_input on exit code 1 (normal completion)" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Exit code 1 indicates Claude CLI finished its turn and is waiting for input
    # This is not a failure - it's normal "conversation paused" behavior
    status = MockProcessManager::MockStatus.new(1)
    decision = manager.handle_exit(status, working_dir: "/tmp/test")

    assert_equal :needs_input, decision.action
    assert_nil decision.error_message
  end

  test "handle_exit returns failed on non-zero exit codes other than 1" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Exit code 2 or higher indicates an actual failure
    status = MockProcessManager::MockStatus.new(2)
    decision = manager.handle_exit(status, working_dir: "/tmp/test")

    assert_equal :failed, decision.action
    assert_match(/exit code: 2/, decision.error_message)
  end

  test "handle_exit returns aborted when session not running" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Simulate session being paused externally
    @session.update!(status: :needs_input)

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test")

    assert_equal :aborted, decision.action
  end

  test "handle_exit logs successful exit" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    manager.handle_exit(status, working_dir: "/tmp/test")

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/Process exited successfully/, log_contents)
  end

  # ===========================================================================
  # Failed Resume Recovery Tests
  # ===========================================================================

  test "handle_exit recovers from failed resume by starting fresh CLI session" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    initial_pid = 12345
    recovery_pid = 99999

    # First spawn (the one that will fail resume)
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: initial_pid, stderr_log_path: stderr_path }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    # Write the "No conversation found" message to stderr
    @mock_file_system.write(
      stderr_path,
      "No conversation found with session ID: c65ced73-208f-4e45-ad49-3ea78cf6c4aa\n"
    )

    # Set up the recovery spawn (execute, not resume)
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: recovery_pid, stderr_log_path: stderr_path }
    end

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action
    assert_nil decision.error_message
    assert_equal :running, manager.current_state

    # Verify execute was called (not resume) for the recovery
    # The initial spawn + recovery spawn = 2 execute calls
    assert_equal 2, @mock_cli_adapter.executed_commands.size
    recovery_command = @mock_cli_adapter.executed_commands.last
    assert_equal @session.prompt, recovery_command[:prompt]
    assert_equal @session.session_id, recovery_command[:session_id]

    # Verify session metadata was updated
    @session.reload
    assert_equal recovery_pid, @session.metadata["process_pid"]
    assert_equal true, @session.metadata["runtime_started"]
  end

  test "handle_exit recovers from failed resume on exit code 1" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: stderr_path }
    end

    @mock_file_system.write(
      stderr_path,
      "No conversation found with session ID: abc123\n"
    )

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    # Exit code 1 (normal completion) should still detect and recover from failed resume
    status = MockProcessManager::MockStatus.new(1)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action
    assert_nil decision.error_message
  end

  test "handle_exit fails when failed resume detected but no original prompt available" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: stderr_path }
    end

    # Clear the session's prompt to simulate a session without an original prompt
    @session.update!(prompt: nil)

    @mock_file_system.write(
      stderr_path,
      "No conversation found with session ID: some-uuid\n"
    )

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_match(/no prompt available/, decision.error_message)
    assert_equal :idle, manager.current_state
  end

  test "handle_exit failed resume recovery prefers the pending follow-up over the original prompt" do
    # Regression: when a --resume fails (e.g. the clone was recreated and the local
    # transcript is gone), recovery restarts fresh. It must restart with the user's
    # pending follow-up (sent_message), not the original session prompt — otherwise
    # the user's just-sent message is silently dropped and the original task re-runs.
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    initial_pid = 12345
    recovery_pid = 99999

    @session.update!(
      metadata: @session.metadata.merge("sent_message" => "remove the beet salad, only need 2 lunches")
    )

    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: initial_pid, stderr_log_path: stderr_path }
    end

    manager = create_manager
    manager.spawn(prompt: "Resume please", working_dir: "/tmp/test-clone")

    @mock_file_system.write(
      stderr_path,
      "No conversation found with session ID: c65ced73-208f-4e45-ad49-3ea78cf6c4aa\n"
    )

    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: recovery_pid, stderr_log_path: stderr_path }
    end

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action
    recovery_command = @mock_cli_adapter.executed_commands.last
    assert_equal "remove the beet salad, only need 2 lunches", recovery_command[:prompt]
    refute_equal @session.prompt, recovery_command[:prompt]
  end

  test "handle_exit fails when failed resume recovery spawn raises an error" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    call_count = 0

    @mock_cli_adapter.execute_hook = ->(opts) do
      call_count += 1
      if call_count == 1
        # First call: initial spawn succeeds
        { pid: 12345, stderr_log_path: stderr_path }
      else
        # Second call: recovery spawn fails
        raise "CLI spawn failed: command not found"
      end
    end

    @mock_file_system.write(
      stderr_path,
      "No conversation found with session ID: some-uuid\n"
    )

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_match(/Failed resume recovery failed/, decision.error_message)
    assert_equal :idle, manager.current_state
  end

  test "handle_exit resets runtime_started metadata during failed resume recovery" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @session.update!(metadata: @session.metadata.merge("runtime_started" => true))

    call_count = 0
    @mock_cli_adapter.execute_hook = ->(opts) do
      call_count += 1
      if call_count == 1
        { pid: 12345, stderr_log_path: stderr_path }
      else
        # Verify runtime_started was reset BEFORE the recovery spawn
        @session.reload
        assert_equal false, @session.metadata["runtime_started"],
          "runtime_started should be reset before recovery spawn"
        { pid: 99999, stderr_log_path: stderr_path }
      end
    end

    @mock_file_system.write(
      stderr_path,
      "No conversation found with session ID: some-uuid\n"
    )

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action

    # After successful recovery, runtime_started should be true again
    @session.reload
    assert_equal true, @session.metadata["runtime_started"]
  end

  # ===========================================================================
  # Codex Runtime Exit Classification Tests
  #
  # Codex does NOT share Claude's "exit 1 means paused for input" convention:
  # exit 0 is success, any non-zero code is a genuine failure. A failed
  # `codex exec resume` exits 1 with a "no rollout found ... -32600" stderr. The
  # exit classifier must be runtime-aware so a Codex failure is reported (or
  # recovered) instead of being faked as a successful, paused turn.
  # ===========================================================================

  def create_codex_session
    Session.create!(
      prompt: "Codex test prompt",
      agent_runtime: "codex",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      metadata: { "clone_path" => "/tmp/codex-clone", "working_directory" => "/tmp/codex-clone" }
    )
  end

  test "Codex exit 1 with 'no rollout found' stderr recovers via fresh start" do
    session = create_codex_session
    stderr_path = "/tmp/codex-clone/codex_stderr.log"
    codex_adapter = MockCodexRuntimeAdapter.new
    codex_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }

    manager = ProcessLifecycleManager.new(
      session: session,
      cli_adapter: codex_adapter,
      process_manager: @mock_process_manager,
      log_buffer: LogBuffer.new(session),
      file_system: @mock_file_system
    )
    manager.spawn(prompt: "Hello", working_dir: "/tmp/codex-clone")

    @mock_file_system.write(
      stderr_path,
      "Error: stream error: no rollout found for thread id 0199c0f6-dead-beef - code -32600\n"
    )

    # Exit 1 = genuine failure for Codex, but this signature is a recoverable
    # failed resume → fresh start, NOT a faked needs_input.
    status = MockProcessManager::MockStatus.new(1)
    decision = manager.handle_exit(status, working_dir: "/tmp/codex-clone")

    assert_equal :continue, decision.action
    assert_nil decision.error_message
    # Recovery used execute (fresh start), dropping the dead resume id.
    assert_equal 2, codex_adapter.executed_commands.size
    assert_equal session.prompt, codex_adapter.executed_commands.last[:prompt]
  end

  test "Codex exit 1 with unrelated stderr fails and surfaces stderr to the user" do
    session = create_codex_session
    stderr_path = "/tmp/codex-clone/codex_stderr.log"
    log_buffer = LogBuffer.new(session)
    codex_adapter = MockCodexRuntimeAdapter.new
    codex_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }

    manager = ProcessLifecycleManager.new(
      session: session,
      cli_adapter: codex_adapter,
      process_manager: @mock_process_manager,
      log_buffer: log_buffer,
      file_system: @mock_file_system
    )
    manager.spawn(prompt: "Hello", working_dir: "/tmp/codex-clone")

    @mock_file_system.write(stderr_path, "Error: codex blew up in an unexpected way\n")

    status = MockProcessManager::MockStatus.new(1)
    decision = manager.handle_exit(status, working_dir: "/tmp/codex-clone")

    assert_equal :failed, decision.action
    assert_match(/exit code: 1/, decision.error_message)
    assert_equal :idle, manager.current_state

    log_buffer.flush
    log_contents = session.logs.reload.map(&:content).join("\n")
    assert_match(/Process failed with exit code: 1/, log_contents)
    assert_match(/codex blew up in an unexpected way/, log_contents,
      "the Codex stderr must be surfaced to the session log, not hidden")
  end

  test "Codex exit 0 with empty stderr is a normal successful completion" do
    session = create_codex_session
    stderr_path = "/tmp/codex-clone/codex_stderr.log"
    codex_adapter = MockCodexRuntimeAdapter.new
    codex_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }

    manager = ProcessLifecycleManager.new(
      session: session,
      cli_adapter: codex_adapter,
      process_manager: @mock_process_manager,
      log_buffer: LogBuffer.new(session),
      file_system: @mock_file_system
    )
    manager.spawn(prompt: "Hello", working_dir: "/tmp/codex-clone")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/codex-clone")

    assert_equal :needs_input, decision.action
    assert_nil decision.error_message
  end

  test "Claude exit 1 still classifies as normal completion (needs_input) — regression guard" do
    # Guards against the Codex fix regressing the Claude convention: Claude Code
    # exits 1 when it finishes a turn and awaits input. The claude_code session
    # from setup uses MockClaudeCliAdapter, whose retry_strategy is the real
    # ClaudeRetryStrategy (normal_completion_exit? → true for exit 1).
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(1)
    decision = manager.handle_exit(status, working_dir: "/tmp/test")

    assert_equal :needs_input, decision.action
    assert_nil decision.error_message
  end

  test "handle_exit returns needs_input when stderr has no failed resume indicator" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: stderr_path }
    end

    # Normal stderr content (no failed resume message)
    @mock_file_system.write(stderr_path, "Some normal debug output\n")

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action
  end

  test "handle_exit returns needs_input when stderr file does not exist" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/nonexistent/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action
  end

  test "handle_exit logs recovery attempt when failed resume is detected" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: stderr_path }
    end

    @mock_file_system.write(
      stderr_path,
      "No conversation found with session ID: some-uuid\n"
    )

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    status = MockProcessManager::MockStatus.new(0)
    manager.handle_exit(status, working_dir: "/tmp/test-clone")

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/Resume failed.*Attempting fresh start recovery/, log_contents)
    assert_match(/Recovering from failed resume.*starting fresh CLI session/, log_contents)
    assert_match(/Fresh start recovery successful/, log_contents)
  end

  # ===========================================================================
  # Running Check Tests
  # ===========================================================================

  test "running? returns true when process is running" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { pid == 12345 }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    assert manager.running?
  end

  test "running? returns false when no process" do
    manager = create_manager
    assert_not manager.running?
  end

  test "running? returns false when process is dead" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { false }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    assert_not manager.running?
  end

  # ===========================================================================
  # Wait Non-Block Tests
  # ===========================================================================

  test "wait_nonblock returns nil when no process" do
    manager = create_manager
    result = manager.wait_nonblock

    assert_nil result
  end

  test "wait_nonblock returns status when process exited" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.wait_hook = ->(pid, flags) do
      [ pid, MockProcessManager::MockStatus.new(0) ]
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    result = manager.wait_nonblock

    assert_not_nil result
    pid, status = result
    assert_equal 12345, pid
    assert status.success?
  end

  test "wait_nonblock handles ECHILD gracefully" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.wait_hook = ->(pid, flags) do
      raise Errno::ECHILD
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    result = manager.wait_nonblock

    assert_nil result
  end

  # ===========================================================================
  # Thread Safety Tests
  # ===========================================================================

  test "concurrent spawn attempts only allow one to succeed" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      sleep(0.1) # Simulate slow spawn
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    results = []
    threads = []

    5.times do
      threads << Thread.new do
        result = manager.spawn(prompt: "Hello", working_dir: "/tmp/test")
        results << result
      end
    end

    threads.each(&:join)

    successful = results.count(&:success?)
    failed = results.count { |r| !r.success? }

    assert_equal 1, successful, "Only one spawn should succeed"
    assert_equal 4, failed, "Four spawns should fail due to state conflict"
  end

  test "concurrent terminate calls only terminate once" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { false }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    results = []
    threads = []

    5.times do
      threads << Thread.new do
        result = manager.terminate(reason: :user_pause)
        results << result
      end
    end

    threads.each(&:join)

    # First terminate succeeds, subsequent ones fail (already terminating/terminated)
    successful = results.count(&:success?)
    assert_operator successful, :>=, 1, "At least one terminate should succeed"

    # State should end up terminated
    assert_equal :terminated, manager.current_state
  end

  test "spawn fails during handle_exit processing" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Use a barrier to ensure we catch the handling_exit state
    spawn_attempted = false
    spawn_result = nil

    # Start handle_exit in background thread with SIGTERM status
    # SIGTERM exits do confirmation checks which take longer
    exit_thread = Thread.new do
      status = MockProcessManager::MockStatus.signaled(15) # SIGTERM
      manager.handle_exit(status, working_dir: "/tmp/test")
    end

    # Poll until we see handling_exit state or thread finishes
    50.times do
      if manager.current_state == :handling_exit
        spawn_result = manager.spawn(prompt: "New prompt", working_dir: "/tmp/test")
        spawn_attempted = true
        break
      end
      sleep(0.01)
    end

    exit_thread.join

    # If we caught the handling_exit state, spawn should have failed
    if spawn_attempted
      assert_not spawn_result.success?
      assert_match(/Cannot spawn/, spawn_result.error)
    else
      # If handle_exit completed too fast, verify we're back in idle and can spawn
      assert_equal :idle, manager.current_state
      skip "handle_exit completed before spawn attempt - race condition test inconclusive"
    end
  end

  test "handle_exit transitions to idle state on failure" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Simulate failed exit (exit code 2+ indicates actual failure)
    # Note: exit code 1 is treated as normal completion (needs_input)
    status = MockProcessManager::MockStatus.new(2)
    decision = manager.handle_exit(status, working_dir: "/tmp/test")

    assert_equal :failed, decision.action
    assert_equal :idle, manager.current_state

    # Should be able to spawn again after failure
    result = manager.spawn(prompt: "New prompt", working_dir: "/tmp/test")
    assert result.success?
  end

  test "spawn fails after resume_monitoring without terminate" do
    @mock_process_manager.running_hook = ->(pid) { true }

    manager = create_manager
    manager.resume_monitoring(pid: 54321, stderr_log_path: "/tmp/stderr.log")

    # Try to spawn while in running state from resume_monitoring
    result = manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    assert_not result.success?
    assert_match(/Cannot spawn.*running/, result.error)
  end

  # ===========================================================================
  # Handle Exit State Transitions Tests
  # ===========================================================================

  test "handle_exit uses handling_exit state during processing" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # We can't easily observe the intermediate state in a single-threaded test,
    # but we can verify the final state is correct
    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test")

    assert_equal :needs_input, decision.action
    assert_equal :idle, manager.current_state
  end

  test "handle_exit returns to idle on exception" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Make session.reload raise an exception
    @session.define_singleton_method(:reload) do
      raise StandardError, "Database error"
    end

    status = MockProcessManager::MockStatus.new(0)

    assert_raises(StandardError) do
      manager.handle_exit(status, working_dir: "/tmp/test")
    end

    # State should have returned to idle despite exception
    assert_equal :idle, manager.current_state
  end

  # ===========================================================================
  # Constants Tests
  # ===========================================================================

  test "status confirmation constants are defined" do
    assert_equal 3, ProcessLifecycleManager::STATUS_CONFIRMATION_CHECKS
    assert_equal 0.2, ProcessLifecycleManager::STATUS_CONFIRMATION_DELAY
  end

  test "states constant includes handling_exit" do
    assert_includes ProcessLifecycleManager::STATES, :handling_exit
  end

  # ===========================================================================
  # CLI Adapter Integration Tests
  # ===========================================================================

  test "cli_adapter receives the same process_manager and file_system" do
    manager = create_manager

    assert_equal @mock_process_manager, @mock_cli_adapter.process_manager
    assert_equal @mock_file_system, @mock_cli_adapter.file_system
  end

  # ===========================================================================
  # Compact Continuation Tests (Issue #618)
  # ===========================================================================

  test "handle_exit auto-continues when pending_compact_continuation is set" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 54321, stderr_log_path: "/tmp/stderr2.log" }
    end

    # Set the pending_compact_continuation flag (simulating post-/compact state)
    @session.update!(metadata: @session.metadata.merge("pending_compact_continuation" => true))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Simulate successful exit (like /compact completing)
    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    # Should continue (spawn new process), not needs_input
    assert_equal :continue, decision.action
    assert_equal :running, manager.current_state

    # Should have spawned a continuation prompt
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length
    assert_equal "Continue with the previous task", @mock_cli_adapter.resumed_sessions.first[:prompt]
  end

  test "handle_exit clears pending_compact_continuation flag after continuation" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 54321, stderr_log_path: "/tmp/stderr2.log" }
    end

    @session.update!(metadata: @session.metadata.merge("pending_compact_continuation" => true))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    manager.handle_exit(status, working_dir: "/tmp/test-clone")

    @session.reload
    assert_nil @session.metadata["pending_compact_continuation"],
      "Should clear pending_compact_continuation flag after successful continuation"
  end

  test "handle_exit clears context_length_last_checked_line when clearing pending_compact_continuation" do
    # This test ensures that after a successful compact continuation,
    # the transcript line tracking is reset so that NEW context length errors
    # in the future can be detected.
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 54321, stderr_log_path: "/tmp/stderr2.log" }
    end

    # Set both flags - simulating state after context length error was detected
    @session.update!(metadata: @session.metadata.merge(
      "pending_compact_continuation" => true,
      "context_length_last_checked_line" => 50
    ))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    manager.handle_exit(status, working_dir: "/tmp/test-clone")

    @session.reload
    assert_nil @session.metadata["pending_compact_continuation"],
      "Should clear pending_compact_continuation flag"
    assert_nil @session.metadata["context_length_last_checked_line"],
      "Should clear context_length_last_checked_line to allow detection of new errors"
  end

  test "handle_exit updates process_pid after compact continuation" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 99999, stderr_log_path: "/tmp/stderr2.log" }
    end

    @session.update!(metadata: @session.metadata.merge("pending_compact_continuation" => true))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    manager.handle_exit(status, working_dir: "/tmp/test-clone")

    @session.reload
    assert_equal 99999, @session.metadata["process_pid"]
    assert_equal 99999, manager.current_pid
  end

  test "handle_exit returns needs_input when no pending_compact_continuation" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # No pending_compact_continuation flag
    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action
    assert_equal :idle, manager.current_state
  end

  test "handle_exit logs compact continuation" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 54321, stderr_log_path: "/tmp/stderr2.log" }
    end

    @session.update!(metadata: @session.metadata.merge("pending_compact_continuation" => true))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    manager.handle_exit(status, working_dir: "/tmp/test-clone")

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/Compact completed successfully.*automatically continuing/, log_contents)
    assert_match(/Spawned continuation process with PID 54321/, log_contents)
  end

  test "handle_exit returns failed when compact continuation spawn fails" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_cli_adapter.resume_hook = ->(opts) do
      raise StandardError, "Spawn failed"
    end

    @session.update!(metadata: @session.metadata.merge("pending_compact_continuation" => true))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_match(/Failed to continue after compact/, decision.error_message)
    assert_equal :idle, manager.current_state
  end

  # ===========================================================================
  # Context Length Error Detection Tests (Issue #615)
  # ===========================================================================

  test "retry_strategy.context_length_error? detects error from transcript API error when stderr is empty" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Setup empty stderr
    @mock_file_system.write("/tmp/stderr.log", "")

    # Setup transcript with API error
    setup_transcript_with_api_error("Prompt is too long")

    assert manager.send(:retry_strategy).context_length_error?(stderr_log_path: "/tmp/stderr.log"),
      "Should detect context length error from transcript"
  end

  test "retry_strategy.context_length_error? returns false when no error in stderr or transcript" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Setup empty stderr
    @mock_file_system.write("/tmp/stderr.log", "")

    # Setup transcript with regular messages (no API error)
    setup_transcript_with_regular_message("Everything is fine")

    assert_not manager.send(:retry_strategy).context_length_error?(stderr_log_path: "/tmp/stderr.log"),
      "Should not detect context length error"
  end

  test "retry_strategy.context_length_error? prefers stderr detection over transcript" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Setup stderr with error
    @mock_file_system.write("/tmp/stderr.log", "Error: prompt is too long")

    # Also setup transcript with API error
    setup_transcript_with_api_error("Prompt is too long")

    assert manager.send(:retry_strategy).context_length_error?(stderr_log_path: "/tmp/stderr.log"),
      "Should detect context length error from stderr"
  end

  test "handle_exit routes to compact recovery when context length error on successful exit" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # Setup transcript with context length error
    setup_transcript_with_api_error("Prompt is too long")

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Simulate successful exit (exit code 0) but with context length error in transcript
    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    # Should route to compact recovery
    # The compact service will return :exhausted since compact_retry_count isn't set up
    assert_equal :failed, decision.action
    assert_match(/Context length/, decision.error_message)

    # Verify logs show the context length error was detected
    log_contents = @session.logs.pluck(:content).join("\n")
    assert_match(/Context length error detected on successful exit/, log_contents)
  end

  private

  # Helper to calculate the transcript directory for the test session
  def calculate_test_transcript_dir
    home_dir = File.expand_path("~")
    claude_projects_dir = File.join(home_dir, ".claude", "projects")
    sanitized_path = PathSanitizer.sanitize("/tmp/test-clone")
    File.join(claude_projects_dir, sanitized_path)
  end

  # Helper to create API error JSON entry
  def api_error_json(message, error_type: "invalid_request")
    JSON.generate({
      "type" => "assistant",
      "isApiErrorMessage" => true,
      "error" => error_type,
      "message" => {
        "model" => "<synthetic>",
        "content" => [ { "type" => "text", "text" => message } ]
      }
    })
  end

  # Helper to setup transcript with API error
  def setup_transcript_with_api_error(message, error_type: "invalid_request")
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Hi there!"}]}}
      #{api_error_json(message, error_type: error_type)}
    JSONL
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), transcript_content)
  end

  # Helper to setup transcript with regular message (not API error)
  def setup_transcript_with_regular_message(message)
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "#{message}"}]}}
    JSONL
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), transcript_content)
  end

  # ============================================================================
  # Prompt Too Long Hang Detection - handle_exit Flag Routing
  # ============================================================================

  test "handle_exit routes to compact recovery when prompt_too_long_hang_detected flag is set" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # Set up transcript with the regular assistant message that triggered hang detection
    setup_transcript_with_regular_message("Prompt is too long")

    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 54321, stderr_log_path: "/tmp/stderr2.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    @session.update!(metadata: @session.metadata.merge("prompt_too_long_hang_detected" => true))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Exit with SIGTERM (exit code 143) - the flag should override normal SIGTERM handling
    status = MockProcessManager::MockStatus.new(143, termsig: 15)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action, "Should route to compact recovery and continue"

    @session.reload
    assert_nil @session.metadata["prompt_too_long_hang_detected"],
      "Should clear prompt_too_long_hang_detected flag"
  end

  test "handle_exit does not route to compact when prompt_too_long_hang_detected flag is absent" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # No prompt_too_long_hang_detected flag
    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action, "Should use normal exit handling"
  end

  test "handle_exit clears prompt_too_long metadata on compact continuation" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 54321, stderr_log_path: "/tmp/stderr2.log" }
    end

    # Simulate the state after hang detection + compact recovery: the first handle_exit
    # cleared prompt_too_long_hang_detected and ran /compact. Now /compact has completed
    # (pending_compact_continuation=true) and we expect compact continuation to clean up
    # the leftover prompt_too_long_hang_detected_at_line metadata.
    @session.update!(metadata: @session.metadata.merge(
      "pending_compact_continuation" => true,
      "prompt_too_long_hang_detected_at_line" => 42
    ))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    manager.handle_exit(status, working_dir: "/tmp/test-clone")

    @session.reload
    assert_nil @session.metadata["prompt_too_long_hang_detected_at_line"],
      "Should clear prompt_too_long_hang_detected_at_line on compact continuation"
    assert_nil @session.metadata["prompt_too_long_hang_detected"],
      "Should clear prompt_too_long_hang_detected on compact continuation"
    assert_nil @session.metadata["pending_compact_continuation"],
      "Should clear pending_compact_continuation"
  end

  # ============================================================================
  # Recovery-Initiated Termination - handle_exit Flag Routing
  # ============================================================================

  test "handle_exit returns aborted when recovery_termination_initiated flag is set with SIGKILL" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    @session.update!(metadata: @session.metadata.merge("recovery_termination_initiated" => true))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # SIGKILL (signal 9) - what the recovery service sends to hung processes
    status = MockProcessManager::MockStatus.signaled(9)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :aborted, decision.action,
      "Should abort when recovery_termination_initiated flag is set"
    assert_equal :idle, manager.current_state
  end

  test "handle_exit returns aborted when recovery_termination_initiated flag is set with SIGTERM" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    @session.update!(metadata: @session.metadata.merge("recovery_termination_initiated" => true))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # SIGTERM (signal 15) - graceful termination attempt before SIGKILL
    status = MockProcessManager::MockStatus.new(143, termsig: 15)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :aborted, decision.action,
      "Should abort when recovery_termination_initiated flag is set even for SIGTERM"
  end

  test "handle_exit does not abort on SIGKILL when recovery_termination_initiated flag is absent" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # No recovery flag set
    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # SIGKILL without recovery flag should still fail normally
    status = MockProcessManager::MockStatus.signaled(9)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action,
      "Should fail normally when recovery flag is absent"
    assert_match(/SIGKILL/, decision.error_message)
  end

  test "handle_exit logs recovery-initiated termination" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    @session.update!(metadata: @session.metadata.merge("recovery_termination_initiated" => true))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.signaled(9)
    manager.handle_exit(status, working_dir: "/tmp/test-clone")

    @log_buffer.flush
    logs = @session.logs.reload
    log_contents = logs.map(&:content).join("\n")

    assert_match(/recovery-initiated/, log_contents)
  end

  # ============================================================================
  # API Server Error Detection and Retry Tests
  # ============================================================================

  test "retry_strategy.api_error_for_retry? detects API server error from transcript" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Setup transcript with API server error
    setup_transcript_with_api_server_error("Internal server error")

    assert manager.send(:retry_strategy).api_error_for_retry?(working_dir: "/tmp/test-clone"),
      "Should detect API server error from transcript"
  end

  test "retry_strategy.api_error_for_retry? returns false when no API server error in transcript" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Setup transcript with regular messages (no API error)
    setup_transcript_with_regular_message("Everything is fine")

    assert_not manager.send(:retry_strategy).api_error_for_retry?(working_dir: "/tmp/test-clone"),
      "Should not detect API server error from regular messages"
  end

  test "retry_strategy.api_error_for_retry? returns false for client errors like invalid_request" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Setup transcript with client error
    setup_transcript_with_api_error("Invalid parameters", error_type: "invalid_request")

    assert_not manager.send(:retry_strategy).api_error_for_retry?(working_dir: "/tmp/test-clone"),
      "Should not detect client errors as API server errors"
  end

  test "handle_exit routes to API error retry on non-zero exit with API server error" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # Setup transcript with API server error
    setup_transcript_with_api_server_error("Internal server error")

    # Setup resume hook for retry - process stays running
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 54321, stderr_log_path: "/tmp/stderr2.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Non-zero, non-SIGTERM exit (e.g., exit code 2)
    status = MockProcessManager::MockStatus.new(2)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action,
      "Should retry on API server error and continue with new process"
  end

  test "handle_exit routes to API error retry on successful exit with API server error in transcript" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # Setup transcript with API server error
    setup_transcript_with_api_server_error("Internal server error")

    # Setup resume hook for retry
    @mock_cli_adapter.resume_hook = ->(opts) do
      { pid: 54321, stderr_log_path: "/tmp/stderr2.log" }
    end
    @mock_process_manager.running_hook = ->(pid) { true }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Exit code 0 (success) but with API error in transcript
    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action,
      "Should retry API server error even on successful exit"

    # Verify logs show the detection
    @log_buffer.flush
    log_contents = @session.logs.pluck(:content).join("\n")
    assert_match(/API server error detected on successful exit/, log_contents)
  end

  test "handle_exit returns failed when API error retry is exhausted" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # Setup transcript with API server error
    setup_transcript_with_api_server_error("Internal server error")

    # Mark retries as exhausted
    @session.update!(metadata: @session.metadata.merge("api_error_retry_count" => 6))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(2)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_match(/API error retry limit exhausted/, decision.error_message)
  end

  test "handle_exit returns needs_input when account quota limit is reached and no rotation available" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # Setup transcript with account quota limit message
    setup_transcript_with_api_server_error(
      "You've hit your limit · resets 5pm (UTC)",
      error_type: "rate_limit_error"
    )

    # Stub rotation to fail (no available accounts)
    AccountRotationService.any_instance.stubs(:rotate!).returns(
      { success: false, reason: "no_available_accounts" }
    )

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Process exits with code 0 (successful exit) but transcript has quota limit
    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action,
      "Quota limit should transition to needs_input, not failed"
    assert_match(/Account quota limit reached/, decision.error_message)
  end

  # ===========================================================================
  # Auth Recovery Tests (rotation-induced "Not logged in / Please run /login")
  # ===========================================================================

  test "handle_exit routes to auth recovery on successful exit and continues" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_with_auth_error("Not logged in · Please run /login")
    stub_auth_provider_returning(fake_account("rotated@example.com"))

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 54321, stderr_log_path: "/tmp/stderr2.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Exit code 0 (success) but transcript shows the rotation-induced auth error.
    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action,
      "Should refresh identity and resume on a rotation-induced auth error"
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length, "Should have re-spawned the session"
    assert_equal :running, manager.current_state
    assert_equal 54321, manager.current_pid

    @log_buffer.flush
    log_contents = @session.logs.pluck(:content).join("\n")
    assert_match(/Not logged in detected on successful exit/, log_contents)
  end

  test "handle_exit routes to auth recovery on a non-zero failure exit and continues" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_with_auth_error("Not logged in · Please run /login")
    stub_auth_provider_returning(fake_account("rotated@example.com"))

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 54321, stderr_log_path: "/tmp/stderr2.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Exit code 2 (genuine failure exit) with the auth error in the transcript.
    status = MockProcessManager::MockStatus.new(2)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action,
      "Auth recovery must also fire from the failure branch of handle_exit"
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length
  end

  test "handle_exit returns needs_input when not logged in and no valid account is available" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_with_auth_error("Not logged in · Please run /login")
    # No valid account to recover to — inject_for_session! returns nil.
    stub_auth_provider_returning(nil)

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action,
      "No recoverable account should surface to the user, not fail silently"
    assert_match(/no valid account available/, decision.error_message)
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length,
      "Must not re-spawn when there is no account to recover to"
  end

  test "handle_exit returns failed when auth recovery is exhausted" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_with_auth_error("Not logged in · Please run /login")
    stub_auth_provider_returning(fake_account("rotated@example.com"))

    # Consecutive-failure budget already used up.
    @session.update!(metadata: @session.metadata.merge("auth_recovery_count" => AuthRecoveryService::MAX_RECOVERY_ATTEMPTS))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(2)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_match(/Auth recovery retry limit exhausted/, decision.error_message)
  end

  test "handle_exit prioritizes auth recovery when auth error is the most recent API error" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    # An older retryable 5xx followed by a newer auth error — auth must win.
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_server_error_json("Internal server error")}
      #{auth_error_json("Not logged in · Please run /login")}
    JSONL
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), transcript_content)

    stub_auth_provider_returning(fake_account("rotated@example.com"))
    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 54321, stderr_log_path: "/tmp/stderr2.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action
    @log_buffer.flush
    log_contents = @session.logs.pluck(:content).join("\n")
    assert_match(/Not logged in detected/, log_contents,
      "Most-recent-error-wins: a fresh auth error after a 5xx routes to auth recovery, not API retry")
  end

  # Auth-error transcript entry, recorded exactly as Claude Code writes the
  # rotation-induced "Not logged in" state (isApiErrorMessage with empty error type).
  def auth_error_json(message)
    JSON.generate({
      "type" => "assistant",
      "isApiErrorMessage" => true,
      "error" => "",
      "message" => {
        "model" => "<synthetic>",
        "content" => [ { "type" => "text", "text" => message } ]
      }
    })
  end

  def setup_transcript_with_auth_error(message)
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Hi there!"}]}}
      #{auth_error_json(message)}
    JSONL
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), transcript_content)
  end

  # Minimal account stand-in — AuthRecoveryService only reads #email for logging.
  def fake_account(email)
    Struct.new(:email).new(email)
  end

  # Stub RuntimeAuthProvider.for so the AuthRecoveryService built inside
  # handle_auth_recovery resolves a fake provider whose inject_for_session!
  # returns the given account (or nil to model "no valid account available").
  def stub_auth_provider_returning(account)
    provider = Object.new
    provider.define_singleton_method(:inject_for_session!) { |_session, _working_directory = nil| account }
    RuntimeAuthProvider.stubs(:for).returns(provider)
  end

  # Helper to create API server error JSON entry
  def api_server_error_json(message, error_type: "api_error")
    JSON.generate({
      "type" => "assistant",
      "isApiErrorMessage" => true,
      "error" => error_type,
      "message" => {
        "model" => "<synthetic>",
        "content" => [ { "type" => "text", "text" => message } ]
      }
    })
  end

  # Helper to setup transcript with API server error
  def setup_transcript_with_api_server_error(message, error_type: "api_error")
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Hi there!"}]}}
      #{api_server_error_json(message, error_type: error_type)}
    JSONL
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), transcript_content)
  end

  # ===========================================================================
  # Account-rotation continuation when the clone directory is gone (regression)
  #
  # Production incident (issue #4623): a session hit its Claude account quota,
  # ProcessLifecycleManager rotated to a fresh account, then tried to resume — but
  # the clone directory had already been removed by the clone GC after the session
  # was torn down. The CLI adapter raised Errno::ENOENT opening claude_stderr.log
  # under the deleted path, which spawn_continuation logged at .error and tripped a
  # critical Grafana alert. A GC'd clone is expected, not broken system behavior, so
  # it must terminate gracefully at warn level without an alertable error log.
  # ===========================================================================

  # Stub RuntimeAuthProvider.for so attempt_account_rotation resolves a fake
  # provider whose rotate_for_quota! reports a successful rotation to `account`.
  def stub_quota_rotation_returning(account)
    provider = Object.new
    provider.define_singleton_method(:rotate_for_quota!) { |triggered_by: nil| { success: true, account: account } }
    RuntimeAuthProvider.stubs(:for).returns(provider)
  end

  test "account rotation continuation terminates gracefully without an error log when the clone directory is gone" do
    stub_quota_rotation_returning(fake_account("rotated@example.com"))

    manager = create_manager
    logger = manager.instance_variable_get(:@logger)
    # The crux of the fix: a missing clone dir is warn-worthy, never error-worthy.
    logger.expects(:error).never
    logger.expects(:warn).with(regexp_matches(/continuation skipped/i), anything).once

    # Clone dir intentionally NOT created in the mock file system → it "no longer exists".
    working_dir = "/tmp/deleted-clone"
    refute @mock_file_system.directory?(working_dir), "guard precondition: clone dir must be absent"

    decision = manager.send(:attempt_account_rotation, working_dir)

    assert_equal :failed, decision.action, "missing clone dir is a terminal condition"
    assert_match(/Clone directory no longer exists/i, decision.error_message)
    assert_empty @mock_cli_adapter.resumed_sessions,
      "resume must be short-circuited before touching the deleted clone"
    assert_equal :idle, manager.current_state
  end

  test "account rotation continuation still logs at error when the clone exists but the resume genuinely fails" do
    stub_quota_rotation_returning(fake_account("rotated@example.com"))

    manager = create_manager
    logger = manager.instance_variable_get(:@logger)
    # Genuine breakage (dir present, CLI still fails to launch) must stay noisy.
    logger.expects(:error).with(regexp_matches(/continuation failed/i), anything).at_least_once

    working_dir = "/tmp/present-clone"
    @mock_file_system.mkdir_p(working_dir)
    @mock_cli_adapter.resume_hook = ->(_opts) { raise ClaudeCliAdapter::ClaudeCliError, "boom" }

    decision = manager.send(:attempt_account_rotation, working_dir)

    assert_equal :failed, decision.action
    assert_match(/Failed to continue after account rotation/i, decision.error_message)
    refute_empty @mock_cli_adapter.resumed_sessions,
      "resume must actually be attempted when the clone dir is present"
  end
end
