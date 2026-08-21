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
      metadata: { "clone_path" => "/tmp/test-clone", "working_directory" => "/tmp/test-clone" },
      # A session whose agent process has run has a transcript. handle_exit treats a
      # session with nothing in EITHER transcript store as "the runtime never got
      # going" and restarts the turn (see #handle_empty_turn), so tests that mean
      # "this process did work and then exited" must not look like a session that
      # never produced a line. Tests for the empty-turn backstop itself blank this
      # out deliberately.
      transcript: { "type" => "user", "message" => { "content" => "Test prompt" } }.to_json
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

  # === One session, one live agent process (zimmer#395) ======================
  #
  # #spawn is the chokepoint every new turn passes through, so it is where the
  # invariant has to hold. These drive the guard through the manager rather than
  # through AgentProcessLiveness directly, because the wiring is the part that
  # regressed: nothing on the spawn path asked about the previous turn's process.

  # Record `pid` as this session's agent process, in a way AgentProcessLiveness will
  # classify as `:alive` — same namespace, same start time — without needing a real
  # process behind the number.
  def record_live_agent_process(pid, boot: "boot-1", namespace: "pid:[1]", ticks: "555")
    @session.merge_metadata!({
      "process_pid" => pid,
      AgentProcessLiveness::IDENTITY_KEY => {
        "pid" => pid, "boot_id" => boot, "pid_namespace" => namespace, "started_at_ticks" => ticks
      }
    })
    @session.reload
  end

  # Stand in for this machine, so the recorded identity classifies as :alive without a
  # real process behind the number.
  def stubbing_this_machine(ticks: "555", &block)
    AgentProcessLiveness.stub(:boot_id, "boot-1") do
      AgentProcessLiveness.stub(:pid_namespace, "pid:[1]") do
        AgentProcessLiveness.stub(:process_snapshot, { state: "S", started_at_ticks: ticks }, &block)
      end
    end
  end

  # Make the mock report `pid` as running until something signals it.
  def mock_live_process(pid)
    @mock_process_manager.set_process_state(pid, :running)
    flip_to_dead = ->(_signal, _target) { @mock_process_manager.set_process_state(pid, :dead) }
    @mock_process_manager.kill_hook = flip_to_dead
    @mock_process_manager.kill_group_hook = flip_to_dead
  end

  test "spawn terminates an agent process left running by a previous turn" do
    # THE #395 REGRESSION. A job whose worker died without running its `ensure` leaves
    # its agent process alive; JobLiveness correctly reports the JOB as supersedable, the
    # next turn spawns, and the two agents race on one branch and one scratch dir. Before
    # this guard, `spawn` simply overwrote process_pid and the old process kept running.
    orphan_pid = 424242
    record_live_agent_process(orphan_pid)
    mock_live_process(orphan_pid)
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    stubbing_this_machine do
      result = create_manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

      assert result.success?, "the new turn must still start — its prompt must not be dropped"
      assert_not @mock_process_manager.running?(orphan_pid),
        "the previous turn's agent process must be dead before a second one starts"
    end

    @log_buffer.flush
    @session.reload
    assert @session.logs.any? { |log| log.content.include?("Previous turn's agent process") }
  end

  test "spawn proceeds even when the orphaned process cannot be terminated" do
    # The asymmetry that governs this whole guard: a double-run is rare and recoverable,
    # a silently dropped turn is neither. If termination fails we say so and spawn anyway.
    orphan_pid = 424243
    record_live_agent_process(orphan_pid)
    @mock_process_manager.set_process_state(orphan_pid, :running)
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    failed = ProcessTerminationService::TerminationResult.new(status: :error, message: "nope")
    termination = Minitest::Mock.new
    termination.expect(:terminate, failed)

    stubbing_this_machine do
      ProcessTerminationService.stub(:new, termination) do
        result = create_manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

        assert result.success?
      end
    end

    termination.verify
    @log_buffer.flush
    @session.reload
    assert @session.logs.any? { |log| log.content.include?("Could not terminate orphaned agent process") }
  end

  test "spawn signals nothing when the recorded pid belongs to another PID namespace" do
    # A pid from a container that has been replaced is not ours to signal, and the
    # process it named died with that container. Guessing "alive" here would mean
    # killing whatever inherited the number in this namespace.
    record_live_agent_process(424244, namespace: "pid:[999999999]")
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    stubbing_this_machine do
      result = create_manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

      assert result.success?
      assert_empty @mock_process_manager.killed_processes
    end
  end

  test "handle_exit does not answer an exit with a respawn once another job owns the session" do
    # The other half of the invariant. The guard above terminates a superseded turn's
    # process — but if that turn's job is still looping, it sees its process exit and
    # would otherwise route a SIGTERM/signal death straight into a retry spawn, putting a
    # second agent back on the clone the guard just cleared.
    @session.update!(running_job_id: "job-that-took-over")
    manager = ProcessLifecycleManager.new(
      session: @session,
      cli_adapter: @mock_cli_adapter,
      process_manager: @mock_process_manager,
      log_buffer: @log_buffer,
      file_system: @mock_file_system,
      owning_job_id: "job-that-was-superseded"
    )

    decision = manager.handle_exit(MockProcessManager::MockStatus.signaled(15), working_dir: "/tmp/test-clone")

    assert_equal :aborted, decision.action
    assert_equal :idle, manager.current_state
    @log_buffer.flush
    assert @session.logs.reload.any? { |log| log.content.include?("Session ownership moved to job") }
  end

  test "handle_exit still handles the exit while this job owns the session" do
    # The other direction: an owning job must keep its retry behaviour. A SIGTERM exit
    # under our own ownership routes into the SIGTERM handler, not the ownership abort.
    @session.update!(running_job_id: "my-job")
    manager = ProcessLifecycleManager.new(
      session: @session,
      cli_adapter: @mock_cli_adapter,
      process_manager: @mock_process_manager,
      log_buffer: @log_buffer,
      file_system: @mock_file_system,
      owning_job_id: "my-job"
    )
    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 22222, stderr_log_path: "/tmp/stderr.log" } }

    manager.handle_exit(MockProcessManager::MockStatus.signaled(15), working_dir: "/tmp/test-clone")

    @log_buffer.flush
    assert_not @session.logs.reload.any? { |log| log.content.include?("Session ownership moved to job") },
      "a job that still owns the session must reach its normal exit handling"
  end

  test "spawn signals nothing when no agent process has been recorded" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    result = create_manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    assert result.success?
    assert_empty @mock_process_manager.killed_processes
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

  test "handle_exit failed resume recovery uses active follow-up prompt after delivery marker is cleared" do
    # Regression for deploy auto-continuation: AgentSessionJob clears
    # pending_follow_up_prompt once it starts delivering the follow-up. If the
    # runtime rejects the resume before the prompt reaches durable transcript
    # state, recovery must use the active per-turn prompt rather than falling
    # back to the original task or failing when no original prompt exists.
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    active_prompt = "[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]\n\nContinue after deploy interruption."

    @session.update!(
      prompt: nil,
      metadata: @session.metadata.merge(
        "active_follow_up_prompt" => active_prompt,
        "sent_message" => "raw web follow-up"
      )
    )

    @mock_cli_adapter.execute_hook = ->(_opts) do
      { pid: 12345, stderr_log_path: stderr_path }
    end

    manager = create_manager
    manager.spawn(prompt: "Resume please", working_dir: "/tmp/test-clone")

    @mock_file_system.write(
      stderr_path,
      "No conversation found with session ID: c65ced73-208f-4e45-ad49-3ea78cf6c4aa\n"
    )

    @mock_cli_adapter.execute_hook = ->(_opts) do
      { pid: 99999, stderr_log_path: stderr_path }
    end

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action
    assert_equal active_prompt, @mock_cli_adapter.executed_commands.last[:prompt]
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
    assert_match(/Fresh start recovery after failed resume failed/, decision.error_message)
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
    assert_equal true, @session.metadata["transcript_recovery_expected"]
    assert_equal @session.transcript_line_count, @session.metadata["transcript_recovery_base_line_count"]
  end

  # ===========================================================================
  # Empty-turn recovery (prod session 4668)
  #
  # An MCP server failed to connect five seconds into the session's first turn.
  # Zimmer killed the process, healed the cache, and scheduled a retry — and then
  # the retry's exit was classified as a completed turn, so the session came to
  # rest in needs_input with a completely blank transcript. Nothing was driving it
  # forward; a human had to notice and type "continue" 3m45s later.
  #
  # The invariant these pin: a normal-looking exit from a runtime that never wrote
  # a single line is not a completed turn, and Zimmer restarts it instead of
  # parking. Deliberately general — it is the backstop behind every specific
  # classifier, not an MCP special case.
  # ===========================================================================

  test "handle_exit restarts the turn when the runtime exited cleanly having written nothing" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @session.update!(transcript: nil)
    @mock_file_system.write(stderr_path, "")

    recovery_pid = 99999
    call_count = 0
    @mock_cli_adapter.execute_hook = ->(opts) do
      call_count += 1
      { pid: call_count == 1 ? 12345 : recovery_pid, stderr_log_path: stderr_path }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action,
      "a turn that produced no transcript at all must not be reported as complete"
    assert_equal :running, manager.current_state
    assert_equal recovery_pid, manager.current_pid,
      "the replacement process must be the one the manager goes on to monitor"

    @session.reload
    assert_equal recovery_pid, @session.metadata["process_pid"]
    assert_equal 1, @session.metadata["empty_turn_recovery_count"]
    assert_equal @session.prompt, @mock_cli_adapter.executed_commands.last[:prompt]
  end

  # Claude exits 1 for "turn finished, awaiting input", so the empty-turn check has
  # to cover that convention too — it is the exit code the real stall arrived on.
  test "handle_exit restarts an empty turn that exited with Claude's normal-completion code 1" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @session.update!(transcript: "")
    @mock_file_system.write(stderr_path, "")
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action
  end

  # The runtime's own transcript file is the other half of the question: a poller
  # that is merely lagging must not be enough for Zimmer to conclude the runtime
  # wrote nothing and abandon a real conversation.
  test "handle_exit parks an empty-in-Zimmer turn when the runtime's own transcript exists" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @session.update!(transcript: nil)
    @mock_file_system.write(stderr_path, "")
    write_runtime_transcript("/tmp/test-clone", @session.session_id)
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action
  end

  test "handle_exit parks an empty turn once the restart budget is spent" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @session.update!(
      transcript: nil,
      metadata: @session.metadata.merge(
        "empty_turn_recovery_count" => ProcessLifecycleManager::MAX_EMPTY_TURN_RECOVERIES
      )
    )
    @mock_file_system.write(stderr_path, "")
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action,
      "the backstop is bounded — a session that stays empty must still be allowed to rest"
    assert_equal :idle, manager.current_state
  end

  # Proves the counter is written on the path that actually loops, rather than
  # only honoured when a test preloads it.
  test "two successive empty turns exhaust the restart budget and then park" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @session.update!(transcript: nil)
    @mock_file_system.write(stderr_path, "")

    pid = 12344
    @mock_cli_adapter.execute_hook = ->(opts) do
      pid += 1
      { pid: pid, stderr_log_path: stderr_path }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    ProcessLifecycleManager::MAX_EMPTY_TURN_RECOVERIES.times do |index|
      decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: "/tmp/test-clone")
      assert_equal :continue, decision.action, "restart #{index + 1} should have been attempted"
      assert_equal index + 1, @session.reload.metadata["empty_turn_recovery_count"]
    end

    final = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, final.action, "the budget must actually run out"
    assert_equal :idle, manager.current_state
  end

  test "handle_exit still parks a turn that produced output" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @mock_file_system.write(stderr_path, "")
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action
    assert_nil @session.reload.metadata["empty_turn_recovery_count"]
  end

  test "handle_exit parks an empty turn when there is no prompt to restart it with" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @session.update!(transcript: nil, prompt: nil)
    @mock_file_system.write(stderr_path, "")
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action,
      "with nothing to replay, restarting cannot help — park as before rather than failing"
  end

  # ===========================================================================
  # Held runtime session id ("Session ID … is already in use")
  #
  # The other half of the 4668 dead end: a replacement process left running by an
  # earlier recovery kept the session id reserved, so the next fresh start was
  # refused — with exit code 1, which Claude uses for "turn complete". The refusal
  # was therefore indistinguishable from success and parked the session again.
  # ===========================================================================

  test "handle_exit mints a new session id when the runtime refuses a held one" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    original_session_id = @session.session_id
    @session.update!(transcript: nil)

    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }
    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    @mock_file_system.write(stderr_path, "Error: Session ID #{original_session_id} is already in use.\n")
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 99999, stderr_log_path: stderr_path } }

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action
    @session.reload
    assert_not_equal original_session_id, @session.session_id,
      "a held id must be replaced, not retried into"
    assert_equal @session.session_id, @mock_cli_adapter.executed_commands.last[:session_id]
    assert_equal 1, @session.metadata["session_id_conflict_count"]
  end

  # The common shape in the wild: the CLI refuses the id precisely because a
  # conversation for it exists. Resuming that conversation is the recovery — it is
  # what a human typing "continue" used to achieve — and minting a new id would
  # throw the history away.
  test "handle_exit resumes the conversation a held session id names" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    original_session_id = @session.session_id
    resume_pid = 77777

    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }
    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    @mock_file_system.write(stderr_path, "Error: Session ID #{original_session_id} is already in use.\n")
    @mock_cli_adapter.resume_hook = ->(opts) { { pid: resume_pid, stderr_log_path: stderr_path } }

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action
    assert_equal resume_pid, manager.current_pid
    assert_equal original_session_id, @session.reload.session_id,
      "minting a new id would abandon a conversation that still has history"
    assert_equal original_session_id, @mock_cli_adapter.resumed_sessions.last[:session_id]
    assert_equal true, @session.metadata["runtime_started"],
      "the refusal is itself evidence the runtime has a conversation under this id"
  end

  test "handle_exit gives up on a held session id once the budget is spent" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @session.update!(
      transcript: nil,
      metadata: @session.metadata.merge(
        "session_id_conflict_count" => ProcessLifecycleManager::MAX_SESSION_ID_CONFLICT_RECOVERIES
      )
    )

    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }
    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    @mock_file_system.write(stderr_path, "Error: Session ID #{@session.session_id} is already in use.\n")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_equal :idle, manager.current_state
  end

  # The runtime's own conversation file, where TranscriptSource#locate looks for it.
  def write_runtime_transcript(working_dir, session_uuid)
    require "path_sanitizer"
    dir = File.join(File.expand_path("~"), ".claude", "projects", PathSanitizer.sanitize(working_dir))
    @mock_file_system.mkdir_p(dir)
    @mock_file_system.write(
      File.join(dir, "#{session_uuid}.jsonl"),
      "#{{ "type" => "user", "message" => { "content" => "Hello" } }.to_json}\n"
    )
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
      metadata: { "clone_path" => "/tmp/codex-clone", "working_directory" => "/tmp/codex-clone" },
      # See the note on the Claude session in `setup`.
      transcript: { "type" => "user", "message" => { "content" => "Codex test prompt" } }.to_json
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
    # ...and the stderr log it now tails is the Codex one, so the NEXT failed
    # resume is still detectable (#187).
    assert_equal stderr_path, manager.stderr_log_path
    assert_not_includes manager.stderr_log_path, "claude_stderr.log",
      "A Codex session must never be handed a Claude stderr filename"
  end

  test "Codex exit 1 with 'no rollout found' recovers with active follow-up prompt" do
    session = create_codex_session
    stderr_path = "/tmp/codex-clone/codex_stderr.log"
    active_prompt = "[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]\n\nContinue after deploy interruption."
    session.update!(
      prompt: nil,
      metadata: session.metadata.merge(
        "active_follow_up_prompt" => active_prompt,
        "sent_message" => "raw web follow-up"
      )
    )
    codex_adapter = MockCodexRuntimeAdapter.new
    codex_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: stderr_path } }

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
      "Error: thread/resume: thread/resume failed: no rollout found for thread id 019fc72f-dead-beef (code -32600)\n"
    )

    status = MockProcessManager::MockStatus.new(1)
    decision = manager.handle_exit(status, working_dir: "/tmp/codex-clone")

    assert_equal :continue, decision.action
    assert_equal active_prompt, codex_adapter.executed_commands.last[:prompt]
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
  # Compact Continuation Tests (Issue pulsemcp/agents#618)
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
  # Context Length Error Detection Tests (Issue pulsemcp/agents#615)
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

  # ===========================================================================
  # Stale runtime session id release after a failed-resume fresh start
  # ===========================================================================
  #
  # Codex ignores the --session-id Zimmer passes and mints a new rollout UUID, so
  # after a fresh start the stored id names a rollout the new process will never
  # write to. Leaving it in place deadlocks transcript polling: the locator keeps
  # returning the abandoned rollout, and the only code that would learn the new
  # UUID reads it from a file the locator never hands over.
  #
  # NOTE: these tests are deliberately above the `private` below. A `test` block
  # after it defines a private method that Minitest silently never runs — see
  # https://github.com/tadasant/zimmer/issues/350.

  test "release_stale_runtime_session_id! clears the id for a runtime that mints its own (Codex)" do
    @session.update!(agent_runtime: "codex")
    @session.update_column(:session_id, "abandoned-rollout-uuid")
    manager = create_manager

    manager.send(:release_stale_runtime_session_id!)
    @log_buffer.flush

    assert_nil @session.reload.session_id,
      "the dead rollout id must be released so the locator falls back to the clone path"
    assert_match(/Releasing stale runtime session id abandoned-rollout-uuid/,
      @session.logs.pluck(:content).join("\n"))
  end

  test "release_stale_runtime_session_id! leaves a Claude session id untouched" do
    @session.update!(agent_runtime: "claude_code")
    @session.update_column(:session_id, "claude-authoritative-uuid")
    manager = create_manager

    manager.send(:release_stale_runtime_session_id!)

    assert_equal "claude-authoritative-uuid", @session.reload.session_id,
      "Claude honors the supplied --session-id, so it stays authoritative across a fresh start"
  end

  test "release_stale_runtime_session_id! is a no-op when there is no id to release" do
    @session.update!(agent_runtime: "codex")
    @session.update_column(:session_id, nil)
    manager = create_manager

    Session.any_instance.expects(:update_column).never
    manager.send(:release_stale_runtime_session_id!)

    assert_nil @session.reload.session_id
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

  test "handle_exit auto-recovers on external SIGKILL when recovery_termination_initiated flag is absent" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/stderr.log" }
    end

    # No recovery flag set — this is a genuinely external SIGKILL (e.g. an OOM kill
    # of a long-running session), distinct from the AO-initiated hung-process
    # termination that sets recovery_termination_initiated (asserted above).
    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    status = MockProcessManager::MockStatus.signaled(9)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    # Rather than surfacing a terminal :failed, an external signal death resumes the
    # existing session so the work continues.
    assert_equal :continue, decision.action,
      "External SIGKILL should auto-recover (resume) rather than fail terminally"
    assert_equal :running, manager.current_state
    assert_equal 1, @session.reload.metadata["signal_death_retry_count"]
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
  # Abnormal Signal Death (OOM / SIGKILL / SIGSEGV) Auto-Recovery Tests
  #
  # Regression coverage for the incident where a long-running, heartbeat-monitored
  # session was cgroup-OOM-killed (SIGKILL/9) and left in a terminal `failed` state
  # until the generic ~15-min stuck-session sweep noticed it. A signal death is now
  # a recoverable/transient condition: the session resumes immediately (bounded by
  # MAX_SIGNAL_DEATH_RETRIES) instead of failing.
  # ============================================================================

  test "signal_death_exit? classifies non-SIGTERM signals as signal death" do
    manager = create_manager

    # Raw signaled exits (termsig set).
    assert manager.send(:signal_death_exit?, MockProcessManager::MockStatus.signaled(9)),
      "SIGKILL (9) is a signal death"
    assert manager.send(:signal_death_exit?, MockProcessManager::MockStatus.signaled(11)),
      "SIGSEGV (11) is a signal death"
    # Shell/wrapper 128+N translation (exit code > 128).
    assert manager.send(:signal_death_exit?, MockProcessManager::MockStatus.new(137)),
      "Exit 137 (128+9, SIGKILL) is a signal death"
    assert manager.send(:signal_death_exit?, MockProcessManager::MockStatus.new(139)),
      "Exit 139 (128+11, SIGSEGV) is a signal death"

    # SIGTERM in either form keeps its dedicated retry path.
    refute manager.send(:signal_death_exit?, MockProcessManager::MockStatus.signaled(15)),
      "SIGTERM (15) has its own retry path, not signal death"
    refute manager.send(:signal_death_exit?, MockProcessManager::MockStatus.new(143, termsig: 15)),
      "Exit 143 (SIGTERM) is not signal death"

    # Normal / non-signal exit codes are not signal death.
    refute manager.send(:signal_death_exit?, MockProcessManager::MockStatus.new(0)),
      "A normal exit is not signal death"
    refute manager.send(:signal_death_exit?, MockProcessManager::MockStatus.new(1)),
      "Exit 1 (normal completion) is not signal death"
    refute manager.send(:signal_death_exit?, MockProcessManager::MockStatus.new(2)),
      "A small non-zero exit code is not signal death"
  end

  test "handle_exit resumes the existing session on OOM SIGKILL instead of failing" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/test-clone/claude_stderr.log" }
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    status = MockProcessManager::MockStatus.signaled(9)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    # Auto-recovers rather than terminal failure.
    assert_equal :continue, decision.action
    assert_nil decision.error_message
    assert_equal :running, manager.current_state

    # Resumed the EXISTING runtime session id with the recovery prompt.
    assert_equal 1, @mock_cli_adapter.resumed_sessions.size
    resume = @mock_cli_adapter.resumed_sessions.last
    assert_equal @session.session_id, resume[:session_id]
    assert_equal AutomatedPrompts::SYSTEM_RECOVERY, resume[:prompt]

    # Tracked the attempt for the bounded retry budget.
    assert_equal 1, @session.reload.metadata["signal_death_retry_count"]
    assert @session.metadata["last_signal_death_at"].present?
  end

  test "handle_exit increments the signal-death retry counter across successive kills" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/test-clone/claude_stderr.log" }
    end

    @session.update!(metadata: @session.metadata.merge("signal_death_retry_count" => 1))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.signaled(9), working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action
    assert_equal 2, @session.reload.metadata["signal_death_retry_count"]
  end

  test "handle_exit fails terminally once the signal-death resume budget is exhausted" do
    @mock_cli_adapter.execute_hook = ->(opts) do
      { pid: 12345, stderr_log_path: "/tmp/test-clone/claude_stderr.log" }
    end

    # Already at the max — the next signal death must not resume again.
    @session.update!(
      metadata: @session.metadata.merge(
        "signal_death_retry_count" => ProcessLifecycleManager::MAX_SIGNAL_DEATH_RETRIES
      )
    )

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.signaled(9), working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_match(/Signal death resume limit exhausted/, decision.error_message)
    assert_equal :idle, manager.current_state
    # No additional resume was attempted.
    assert_equal 0, @mock_cli_adapter.resumed_sessions.size
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

    # The bare needs_input is not enough on its own — the session must be parked
    # with an explanation and a scheduled retry.
    @session.reload
    assert_equal AuthOutageParkService::AUTH_UNRECOVERABLE, @session.metadata["auth_outage_reason"]
    assert_not_nil @session.metadata["auth_outage_retry_at"]
    assert_not_nil Trigger.find_by(last_session_id: @session.id),
      "A wake-up trigger must be scheduled so the session retries on its own"
  end

  test "handle_exit parks the session for retry when auth recovery is exhausted" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_with_auth_error("Not logged in · Please run /login")
    stub_auth_provider_returning(fake_account("rotated@example.com"))

    # Consecutive-failure budget already used up.
    @session.update!(metadata: @session.metadata.merge("auth_recovery_count" => AuthRecoveryService::MAX_RECOVERY_ATTEMPTS))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(2)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    # A hard `failed` used to be the outcome here. The cause is usually a
    # transient token rejection that heals on its own, so the session is parked
    # for an automatic retry instead of needing a human to notice and restart it.
    assert_equal :needs_input, decision.action
    assert_match(/Auth recovery retry limit exhausted/, decision.error_message)

    @session.reload
    assert_equal AuthOutageParkService::AUTH_UNRECOVERABLE, @session.metadata["auth_outage_reason"]
    assert_equal true, @session.metadata["pending_sleep"],
      "Parking must make the session dormant so the heartbeat sweep cannot re-nudge it"
  end

  # The user-visible half of the fix. Before this, a "Not logged in" caused by an
  # exhausted account pool re-spawned three times (showing the runtime's error
  # each time) and then parked with AUTH_UNRECOVERABLE — "re-authenticate an
  # account" — when the actual remedy was to wait for the quota window. Now the
  # FIRST failure lands on QUOTA_EXHAUSTED, whose banner says "wait for reset"
  # and whose retry is derived from the pool's reset times.
  test "handle_exit parks with QUOTA_EXHAUSTED on the first not-logged-in when the pool is drained by quota" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_with_auth_error("Not logged in · Please run /login")
    ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    stub_auth_provider_returning(fake_account("dead@example.com"), rotate_to: nil)

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(0)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action
    assert_match(/quota/i, decision.error_message)
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length,
      "Re-spawning into a wall only a quota reset can clear is the bug being fixed"

    @session.reload
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, @session.metadata["auth_outage_reason"],
      "AUTH_UNRECOVERABLE tells the user to re-authenticate — wrong instruction for a quota outage"
    assert_nil @session.metadata["auth_recovery_count"],
      "Parking on a drained pool is not a retry attempt"
  end

  # Same correction, reached the other way: the budget runs out while the pool is
  # drained by quota. The park reason follows the pool, not the counter.
  test "handle_exit parks an exhausted auth budget with QUOTA_EXHAUSTED when the pool is drained by quota" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_with_auth_error("Not logged in · Please run /login")
    ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    stub_auth_provider_returning(fake_account("dead@example.com"), rotate_to: nil)
    @session.update!(metadata: @session.metadata.merge("auth_recovery_count" => AuthRecoveryService::MAX_RECOVERY_ATTEMPTS))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(2), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action
    assert_match(/quota/i, decision.error_message)
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, @session.reload.metadata["auth_outage_reason"]
  end

  test "auth recovery rotates rather than re-injecting the account that just failed" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }
    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 54321, stderr_log_path: "/tmp/stderr2.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    setup_transcript_with_auth_error("Not logged in · Please run /login")
    failed = fake_account("failed@example.com")
    provider = stub_auth_provider_returning(fake_account("fresh@example.com"), current: failed)
    @session.update!(metadata: @session.metadata.merge(
      AuthRecoveryCoordinator::IDENTITY_KEY => failed.email
    ))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action
    assert_equal [ "auth_recovery" ], provider.rotation_reasons,
      "The pool must be moved, and the move must be labelled as auth recovery rather than quota"
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

  # ===========================================================================
  # The 2026-08-20 incident: a turn that dies on an auth error must never be
  # indistinguishable from a turn that completed (production session 6412).
  # ===========================================================================

  # Reproduce-and-fix. Before this change every classifier said "not mine" for
  # the entry below, so handle_exit fell through to `Process exited successfully`
  # → needs_input, and a human's message sat unanswered with nothing in the logs.
  test "handle_exit routes a dead OAuth session to auth recovery instead of parking it as a completed turn" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_with_oauth_expiry_error
    stub_auth_provider_returning(fake_account("rotated@example.com"))

    @mock_cli_adapter.resume_hook = ->(_opts) { { pid: 54321, stderr_log_path: "/tmp/stderr2.log" } }
    @mock_process_manager.running_hook = ->(_pid) { true }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    # Exit 1 — Claude's "turn finished, awaiting input" convention, which is what
    # made the failure look like an ordinary completion.
    status = MockProcessManager::MockStatus.new(1)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :continue, decision.action,
      "A dead OAuth session must rotate and resume, not park as if the turn had finished"
    assert_equal 1, @mock_cli_adapter.resumed_sessions.length

    @log_buffer.flush
    log_contents = @session.logs.pluck(:content).join("\n")
    assert_match(/Not logged in detected on successful exit/, log_contents)
    assert_no_match(/Process exited successfully/, log_contents,
      "The turn did not complete, so nothing may report that it did")
  end

  # The structural backstop, and the half that matters more: even for an error
  # NO classifier knows, a turn that ends on one can never be reported as done.
  test "handle_exit fails loudly when a turn ends on an API error no classifier recognizes" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_ending_with_api_error(
      "Your quantum entitlement has decohered",
      error_type: "wording_nobody_has_written_yet"
    )

    reported = nil
    UnclassifiedFailureReporter.stubs(:report).returns(true).with do |*args, **kwargs|
      reported = kwargs.presence || args.first
      true
    end

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    status = MockProcessManager::MockStatus.new(1)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action,
      "A turn that ended on an unrecognized API error must fail loudly, not park as needs_input"
    assert_match(/Your quantum entitlement has decohered/, decision.error_message)
    assert_equal 0, @mock_cli_adapter.resumed_sessions.length

    @log_buffer.flush
    log_contents = @session.logs.pluck(:content).join("\n")
    assert_match(/Turn ended on an unrecognized API error/, log_contents)

    assert_equal "terminal API error", reported[:kind], "The unknown must announce itself"
    assert_match(/Your quantum entitlement has decohered/, reported[:output],
      "The alert must carry the prose no pattern matched, so the next wording change is a Slack message"
    )
    assert_no_match(/#{@session.id}/, reported[:summary],
      "The summary is the dedup key — a fleet-wide wave must collapse into one alert"
    )
  end

  # The runtime writes bookkeeping entries (last-prompt, atis-latch) AFTER the
  # final message of a turn. Reading "the last line" rather than "the last
  # message" would let those hide the error the turn died on — which is exactly
  # how the real session 6412 transcript is shaped.
  test "handle_exit still sees a terminal API error behind the runtime's trailing bookkeeping entries" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("Unrecognized meltdown", error_type: "novel_failure")}
      {"type": "last-prompt", "prompt": "Hello"}
      {"type": "atis-latch", "value": 1}
    JSONL

    UnclassifiedFailureReporter.stubs(:report).returns(true)

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action,
      "Trailing bookkeeping entries must not be mistaken for the turn making progress"
  end

  # The guard on the guard: an unrecognized error the turn RECOVERED from is not
  # a terminal error, and must still park normally.
  test "handle_exit still returns needs_input when real output follows an unrecognized API error" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json("Unrecognized hiccup", error_type: "novel_failure")}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "Recovered and finished the work."}]}}
    JSONL

    UnclassifiedFailureReporter.expects(:report).never

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action,
      "An error the turn recovered from must not fail a turn that really did complete"
  end

  # A subagent's API error does not end the main turn.
  test "handle_exit ignores a sidechain API error when deciding whether the turn died" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    sidechain_error = JSON.parse(api_error_json("Subagent blew up", error_type: "novel_failure"))
      .merge("isSidechain" => true)
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      {"type": "assistant", "message": {"content": [{"type": "text", "text": "All done."}]}}
      #{JSON.generate(sidechain_error)}
    JSONL

    UnclassifiedFailureReporter.expects(:report).never

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action,
      "A subagent's failure must not be read as the main turn dying"
  end

  # The hole the first cut of this backstop left: a RECOGNIZED error whose
  # classifier has already spent its cursor still ends a turn, and still has to
  # fail rather than park. It just must not page as an unknown wording.
  test "handle_exit fails a turn that ended on a recognized error no classifier will act on" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_ending_with_api_error("500 Internal Server Error", error_type: "api_error")
    # The retry path already handled this entry and advanced its cursor, so
    # api_error_for_retry? now declines — leaving the turn dead and unclaimed.
    @session.update!(metadata: @session.metadata.merge("api_error_last_checked_line" => 99))

    UnclassifiedFailureReporter.expects(:report).never

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action,
      "A dead turn is a dead turn even when something recognizes the wording"
    @log_buffer.flush
    assert_match(/no recovery path claimed it/, @session.logs.pluck(:content).join("\n"))
  end

  # Fire once per dead turn. A resume that writes nothing new leaves the same
  # entry terminal; re-failing on it would turn one bad turn into a loop.
  test "handle_exit does not fail twice on the same terminal API error" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_ending_with_api_error("Novel meltdown", error_type: "novel_failure")
    UnclassifiedFailureReporter.stubs(:report).returns(true)

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")
    first = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")
    assert_equal :failed, first.action

    @session.update!(status: :running)
    manager2 = create_manager
    manager2.spawn(prompt: "Hello", working_dir: "/tmp/test")
    second = manager2.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, second.action,
      "The same dead turn must not be failed and alerted on again"
  end

  # A backstop that cannot answer must not become the thing that breaks exit
  # handling — it sits on the hot path for every normal completion.
  test "handle_exit parks as before when the terminal-error check raises" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_with_regular_message("All done")

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")
    manager.send(:retry_strategy).stubs(:terminal_api_error).raises(RuntimeError, "transcript on fire")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(1), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action,
      "A raising backstop falls through to the pre-existing park rather than breaking exit handling"
  end

  # Exactly the entry Claude Code 2.1.237 wrote into production session 6412.
  def setup_transcript_with_oauth_expiry_error
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "btw i think you misunderstood my ask"}]}}
      #{api_error_json("Failed to authenticate: OAuth session expired and could not be refreshed", error_type: "authentication_failed")}
    JSONL
  end

  def setup_transcript_ending_with_api_error(message, error_type:)
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), <<~JSONL)
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_error_json(message, error_type: error_type)}
    JSONL
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

  # Fake runtime auth provider satisfying the seam AuthRecoveryCoordinator drives.
  # #accounts is the REAL fixture pool so the coordinator's park-reason read
  # (available? / quota_exceeded?) is truthful; the filesystem writes are not.
  class FakePoolProvider
    attr_reader :rotation_reasons

    def initialize(current:, rotate_to:, inject:)
      @current = current
      @rotate_to = rotate_to
      @inject = inject
      @rotation_reasons = []
    end

    def accounts = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME)
    def current_account = @current
    def refresh!(_account) = RuntimeAuthProvider::Result.new(ok: true, error: nil)
    def inject_for_session!(_session = nil, _working_directory = nil) = @inject

    def rotate_for_quota!(triggered_by: nil, reason: "quota_exceeded", expected_current_email: nil)
      @rotation_reasons << reason
      return { success: false, reason: "no_available_accounts" } unless @rotate_to

      { success: true, account: @rotate_to }
    end
  end

  # Stub RuntimeAuthProvider.for so the AuthRecoveryCoordinator built inside
  # handle_auth_recovery resolves a fake pool. `account` is what the coordinator
  # ends up with (nil models "nothing usable to recover to").
  def stub_auth_provider_returning(account, current: nil, rotate_to: :same)
    provider = FakePoolProvider.new(
      current: current || account,
      rotate_to: rotate_to == :same ? account : rotate_to,
      inject: account
    )
    RuntimeAuthProvider.stubs(:for).returns(provider)
    provider
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
  # Production incident (issue pulsemcp/pulsemcp#4623): a session hit its Claude account quota,
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
    provider.define_singleton_method(:rotate_for_quota!) do |triggered_by: nil, reason: "quota_exceeded", expected_current_email: nil|
      { success: true, account: account }
    end
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

  # ===========================================================================
  # Pool exhaustion — quota hit with nothing left to rotate into
  # ===========================================================================

  test "quota exhaustion with no rotation target parks the session with a scheduled retry" do
    provider = Object.new
    provider.define_singleton_method(:rotate_for_quota!) do |triggered_by: nil, reason: "quota_exceeded", expected_current_email: nil|
      { success: false, reason: "no_available_accounts" }
    end
    RuntimeAuthProvider.stubs(:for).returns(provider)

    setup_transcript_with_quota_error
    manager = create_manager

    decision = manager.send(:handle_retryable_api_error, "/tmp/test-clone")

    assert_equal :needs_input, decision.action
    assert_match(/no other accounts available/, decision.error_message)
    assert_empty @mock_cli_adapter.resumed_sessions,
      "There is nothing to rotate into — re-spawning would hit the same wall"

    @session.reload
    assert_equal AuthOutageParkService::QUOTA_EXHAUSTED, @session.metadata["auth_outage_reason"]
    assert_not_nil @session.metadata["auth_outage_retry_at"]
    assert_equal true, @session.metadata["pending_sleep"]

    @log_buffer.flush
    assert_match(/Quota exceeded across all/, @session.logs.pluck(:content).join("\n"))
  end

  # A parked exit must always reach pause! — that is where pending_sleep is
  # consumed and the session actually goes dormant. Handing off to a queued
  # message instead would keep it running and re-spawn it into the same wall,
  # which is why AgentSessionJob reads the park marker rather than sniffing the
  # error string (an exhausted auth park says nothing about "quota").
  test "a parked exit records the park marker AgentSessionJob gates the handoff on" do
    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    setup_transcript_with_auth_error("Not logged in · Please run /login")
    stub_auth_provider_returning(fake_account("rotated@example.com"))
    @session.update!(metadata: @session.metadata.merge("auth_recovery_count" => AuthRecoveryService::MAX_RECOVERY_ATTEMPTS))

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(2), working_dir: "/tmp/test-clone")

    assert_equal :needs_input, decision.action
    assert_not_includes decision.error_message, "Account quota limit",
      "This park is not a quota park — a string sniff would miss it"
    assert @session.reload.metadata["auth_outage_reason"].present?,
      "The marker must be set before AgentSessionJob inspects it"
  end

  # ===========================================================================
  # Rebuilt stderr log path (#187)
  # ===========================================================================
  #
  # After a recovery spawn, the manager rebuilds the stderr path it tails from
  # session state. Building it from the clone root, or with a hardcoded Claude
  # filename, points a recovered session at a file that does not exist — and
  # both context-length and failed-resume recovery are DETECTED by reading that
  # file, so the next recovery silently never fires.

  test "recovery rebuilds the stderr path under the working directory, not the clone root" do
    clone_path = "/tmp/agent-root-clone"
    working_dir = "/tmp/agent-root-clone/apps/web"
    stderr_path = File.join(working_dir, "claude_stderr.log")
    @mock_file_system.mkdir_p(working_dir)
    @session.update!(metadata: @session.metadata.merge(
      "clone_path" => clone_path, "working_directory" => working_dir
    ))

    @mock_cli_adapter.execute_hook = ->(_opts) { { pid: 12345, stderr_log_path: stderr_path } }

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: working_dir)

    # A failed-resume signature routes through the recovery path, which resets
    # the manager's stderr path after respawning.
    @mock_file_system.write(stderr_path, "No conversation found with session ID: some-uuid\n")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: working_dir)

    assert_equal :continue, decision.action
    assert_equal stderr_path, manager.stderr_log_path,
      "The rebuilt path must be the working directory's log — the clone root's does not exist"
    refute_equal File.join(clone_path, "claude_stderr.log"), manager.stderr_log_path
  end

  # ===========================================================================
  # Unclassified failures announce themselves (#53)
  # ===========================================================================

  # Every branch above this one is a pattern match against the runtime's own
  # prose. Reaching the generic failure path means none of them recognized the
  # death — either a novel failure or, the case that has actually bitten us, a
  # classifier that went stale when the CLI reworded something. It used to look
  # identical to an ordinary failure.
  test "handle_exit alerts with the stderr tail when no classifier matches the exit" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }
    @mock_file_system.write(stderr_path, "Error: the CLI invented a brand new way to die\n")

    alert = nil
    AlertService.stubs(:raise_alert).with do |title, opts|
      alert = [ title, opts ]
      true
    end.returns(true)

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    status = MockProcessManager::MockStatus.new(2)
    decision = manager.handle_exit(status, working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action, "the session must still fail exactly as before"
    assert alert, "an unclassified exit must page"
    assert_equal "Unclassified failure: process exit", alert[0]
    assert_match(/exit code: 2/, alert[1][:details])
    assert_match(/brand new way to die/, alert[1][:error],
      "the alert must carry the output no pattern matched, via error: so AlertSnippet redacts it")
    assert_equal "ProcessLifecycleManager#handle_exit", alert[1][:source]
  end

  # The noise constraint: an exit a classifier DOES recognize is an ordinary,
  # expected event and must never reach the unclassified path.
  test "handle_exit does not alert on a normal completion" do
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }
    AlertService.expects(:raise_alert).never

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(0), working_dir: "/tmp/test-clone")
    assert_equal :needs_input, decision.action
  end

  test "handle_exit does not alert on a classified failed-resume recovery" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }
    @mock_file_system.write(stderr_path, "No conversation found with session ID: abc123\n")
    AlertService.expects(:raise_alert).never

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(2), working_dir: "/tmp/test-clone")
    assert_equal :continue, decision.action
  end

  # The retry-service half: the runtime contributes the transcript prose that no
  # classifier matched, so the alert carries the actual wording rather than just
  # an exit code.
  test "handle_exit carries the unmatched transcript API error into the alert" do
    stderr_path = "/tmp/test-clone/claude_stderr.log"
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: stderr_path } }

    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    @mock_file_system.write(
      File.join(transcript_dir, "#{@session.session_id}.jsonl"),
      "#{api_error_json("Your account has been placed in cool-down mode", error_type: "invalid_request")}\n"
    )

    alert = nil
    AlertService.stubs(:raise_alert).with do |_title, opts|
      alert = opts
      true
    end.returns(true)

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")
    manager.handle_exit(MockProcessManager::MockStatus.new(2), working_dir: "/tmp/test-clone")

    assert alert, "an unclassified exit must page"
    assert_match(/cool-down mode/, alert[:error])
  end

  # A classifier said a recovery path applied and the recovery service then said
  # it did not. Both branches are commented "shouldn't happen" and both fail the
  # session; the disagreement itself is the unknown worth announcing.
  test "handle_exit alerts when a classifier and its recovery service disagree" do
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }
    ClaudeRetryStrategy.any_instance.stubs(:api_error_for_retry?).returns(true)
    ApiErrorRetryService.any_instance.stubs(:attempt_retry).returns(:not_applicable)

    alert = nil
    AlertService.stubs(:raise_alert).with do |title, opts|
      alert = [ title, opts ]
      true
    end.returns(true)

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(2), working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_equal "API server error recovery failed", decision.error_message
    assert alert, "a classifier/service disagreement must page"
    assert_equal "Unclassified failure: recovery contradiction", alert[0]
    assert_match(/handle_retryable_api_error/, alert[1][:details])
    assert_match(/not_applicable/, alert[1][:details])
  end

  # The largest noise risk in the change. CodexRetryStrategy classifies nothing
  # but a missing rollout, so an ordinary Codex failure ALWAYS reaches the
  # unclassified branch — that is its documented design, not news. Paging on it
  # would be a standing hourly alert for expected behavior.
  test "a runtime whose strategy classifies nothing logs but does not page" do
    @session.update!(agent_runtime: "codex")
    @mock_cli_adapter.stubs(:retry_strategy).returns(
      CodexRetryStrategy.new(
        cli_adapter: @mock_cli_adapter, session: @session, file_system: @mock_file_system,
        process_manager: @mock_process_manager, rate_limit_tracker: nil, logger: Rails.logger
      )
    )
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }
    AlertService.expects(:raise_alert).never

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(2), working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action, "the session still fails — only the page is withheld"
  end

  # The summary IS the dedup key, so it must carry the runtime. Without it a
  # routine failure on one runtime holds the key and suppresses a genuinely
  # novel failure on another that happens to share its exit code.
  test "the unclassified alert dedup key distinguishes runtimes sharing an exit code" do
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }

    alert = nil
    AlertService.stubs(:raise_alert).with do |_title, opts|
      alert = opts
      true
    end.returns(true)

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")
    manager.handle_exit(MockProcessManager::MockStatus.new(2), working_dir: "/tmp/test-clone")

    assert alert
    assert_match(/claude_code/, alert[:details],
      "the runtime must reach the alert, because the summary is the dedup key")
  end

  # A signal death that exhausts its resume budget IS classified — it returns
  # before the general branch. Pinning it stops a future refactor from turning a
  # known failure mode into a page.
  test "an exhausted signal-death budget does not alert" do
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }
    @session.update!(metadata: @session.metadata.merge(
      "signal_death_retry_count" => ProcessLifecycleManager::MAX_SIGNAL_DEATH_RETRIES
    ))
    AlertService.expects(:raise_alert).never

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.signaled(9), working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_match(/Signal death resume limit exhausted/, decision.error_message)
  end

  # The context-length arm of the same contradiction, so the branch is not
  # covered only through the API-error handler.
  test "a context length classifier that disagrees with its service also alerts" do
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }
    ClaudeRetryStrategy.any_instance.stubs(:context_length_error?).returns(true)
    ContextLengthRetryService.any_instance.stubs(:attempt_recovery).returns(:not_applicable)

    alert = nil
    AlertService.stubs(:raise_alert).with do |title, opts|
      alert = [ title, opts ]
      true
    end.returns(true)

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(2), working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_equal "Context length error recovery failed", decision.error_message
    assert alert
    assert_equal "Unclassified failure: recovery contradiction", alert[0]
    assert_match(/handle_context_length_error/, alert[1][:details])
  end

  # Alerting must never be able to change how the session itself is failed.
  test "a failing alert does not change the exit decision" do
    @mock_cli_adapter.execute_hook = ->(opts) { { pid: 12345, stderr_log_path: "/tmp/stderr.log" } }
    AlertService.stubs(:raise_alert).raises(StandardError, "slack is on fire")

    manager = create_manager
    manager.spawn(prompt: "Hello", working_dir: "/tmp/test-clone")

    decision = manager.handle_exit(MockProcessManager::MockStatus.new(2), working_dir: "/tmp/test-clone")

    assert_equal :failed, decision.action
    assert_match(/exit code: 2/, decision.error_message)
    assert_equal :idle, manager.current_state
  end

  # The quota signature ApiErrorRetryService classifies as :quota_exceeded.
  def setup_transcript_with_quota_error
    transcript_dir = calculate_test_transcript_dir
    @mock_file_system.mkdir_p(transcript_dir)
    transcript_content = <<~JSONL
      {"type": "user", "message": {"content": [{"type": "text", "text": "Hello"}]}}
      #{api_server_error_json("You've hit your 5-hour limit. Your limit resets at 3pm.")}
    JSONL
    @mock_file_system.write(File.join(transcript_dir, "#{@session.session_id}.jsonl"), transcript_content)
  end
end
