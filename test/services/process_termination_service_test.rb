require "test_helper"
require "mocha/minitest"

class ProcessTerminationServiceTest < ActiveSupport::TestCase
  setup do
    @mock_process_manager = MockProcessManager.new
  end

  # Helper to create a service with process_info stubbed to show process exists
  def create_service_with_existing_process(pid:, process_manager:, **options)
    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: process_manager,
      **options
    )
    # Stub process_info to report process exists and is owned by us
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: true, uid: Process.uid, state: "S" }
    end
    service
  end

  # === Tests for TerminationResult struct ===

  test "TerminationResult success? returns true for terminated status" do
    result = ProcessTerminationService::TerminationResult.new(status: :terminated, message: "test")
    assert result.success?
  end

  test "TerminationResult success? returns true for already_dead status" do
    result = ProcessTerminationService::TerminationResult.new(status: :already_dead, message: "test")
    assert result.success?
  end

  test "TerminationResult success? returns true for zombie_reaped status" do
    result = ProcessTerminationService::TerminationResult.new(status: :zombie_reaped, message: "test")
    assert result.success?
  end

  test "TerminationResult success? returns false for permission_denied status" do
    result = ProcessTerminationService::TerminationResult.new(status: :permission_denied, message: "test")
    assert_not result.success?
  end

  test "TerminationResult success? returns false for error status" do
    result = ProcessTerminationService::TerminationResult.new(status: :error, message: "test")
    assert_not result.success?
  end

  # === Tests for terminate method ===

  test "terminate returns structured result with status and message" do
    pid = @mock_process_manager.spawn("test-command")

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    result = service.terminate

    assert_instance_of ProcessTerminationService::TerminationResult, result
    assert result.success?
    assert_not_nil result.message
  end

  test "terminate sends SIGTERM to process group first" do
    pid = @mock_process_manager.spawn("test-command")

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    service.terminate

    # Verify SIGTERM was sent to process group
    assert @mock_process_manager.killed_processes.any? { |p| p[:signal] == "TERM" && p[:pid] == -pid }
  end

  test "terminate returns already_dead status when process not found via process_info" do
    service = ProcessTerminationService.new(
      process_pid: 99999,
      process_manager: @mock_process_manager
    )
    # process_info will return exists: false since ps won't find pid 99999

    result = service.terminate

    assert result.success?
    assert_equal :already_dead, result.status
  end

  test "terminate returns terminated status when process is successfully terminated" do
    pid = @mock_process_manager.spawn("test-command")

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    result = service.terminate

    assert result.success?
    assert_equal :terminated, result.status
  end

  test "terminate logs termination messages" do
    pid = @mock_process_manager.spawn("test-command")

    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager,
      session: session
    )

    service.terminate

    logs = session.logs
    assert logs.any? { |log| log.content.include?("Terminating process") }
    assert logs.any? { |log| log.content.include?("terminated successfully") }
  end

  test "terminate uses log buffer when provided" do
    pid = @mock_process_manager.spawn("test-command")

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )

    service.terminate

    assert logged_messages.any? { |log| log[:content].include?("Terminating process") }
    assert logged_messages.any? { |log| log[:content].include?("terminated successfully") }
  end

  test "terminate returns permission_denied status and never raises" do
    pid = @mock_process_manager.spawn("test-command")

    # Keep process "running" to simulate permission denied scenario
    # where we can't actually kill the process
    @mock_process_manager.running_hook = ->(check_pid) { check_pid == pid }

    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      raise Errno::EPERM
    }

    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager,
      session: session
    )

    # Should not raise
    result = assert_nothing_raised { service.terminate }

    assert_not result.success?
    assert_equal :permission_denied, result.status
    assert session.logs.any? { |log| log.content.include?("Permission denied") }
  end

  test "terminate returns already_dead status when process_pid is nil" do
    service = ProcessTerminationService.new(
      process_pid: nil,
      process_manager: @mock_process_manager
    )

    result = service.terminate

    assert result.success?
    assert_equal :already_dead, result.status
    assert_match(/No process ID provided/, result.message)
  end

  # === Tests for process_info method ===

  test "process_info returns hash with expected keys" do
    service = ProcessTerminationService.new(
      process_pid: 99999,
      process_manager: @mock_process_manager
    )

    info = service.process_info

    assert_kind_of Hash, info
    assert info.key?(:exists)
    assert info.key?(:is_zombie)
    assert info.key?(:owned_by_us)
    assert info.key?(:uid)
    assert info.key?(:state)
  end

  test "process_info returns exists false for non-existent process" do
    service = ProcessTerminationService.new(
      process_pid: 99999,
      process_manager: @mock_process_manager
    )

    info = service.process_info

    assert_not info[:exists]
  end

  # === Tests for zombie process handling ===

  test "terminate handles zombie processes by reaping" do
    pid = @mock_process_manager.spawn("test-command")
    @mock_process_manager.set_process_state(pid, :zombie)

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )

    # Mock process_info to simulate zombie detection
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: true, owned_by_us: true, uid: Process.uid, state: "Z" }
    end

    result = service.terminate

    assert result.success?
    assert_equal :zombie_reaped, result.status
    assert logged_messages.any? { |log| log[:content].include?("zombie") }
  end

  # === Tests for fallback termination strategies ===

  test "terminate falls back to individual process when group kill fails with ESRCH" do
    pid = @mock_process_manager.spawn("test-command")
    call_count = 0

    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      call_count += 1
      if target_pid < 0
        # Process group kill - fail with ESRCH
        raise Errno::ESRCH
      else
        # Individual process kill - succeed
        @mock_process_manager.set_process_state(pid, :dead)
        1
      end
    }

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager
    )

    result = service.terminate

    assert result.success?
    # Should have tried group first, then individual
    assert call_count >= 2
  end

  test "terminate falls back to individual process when group kill fails with EPERM" do
    pid = @mock_process_manager.spawn("test-command")
    group_kill_attempted = false

    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      if target_pid < 0
        # Process group kill - fail with permission denied
        group_kill_attempted = true
        raise Errno::EPERM
      else
        # Individual process kill - succeed
        @mock_process_manager.set_process_state(pid, :dead)
        1
      end
    }

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )
    # Stub process_info
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: true, uid: Process.uid, state: "S" }
    end

    result = service.terminate

    assert result.success?
    assert group_kill_attempted
    # Should log that it tried group first
    assert logged_messages.any? { |log| log[:content].include?("Permission denied for process group") }
  end

  test "terminate escalates to SIGKILL when SIGTERM fails" do
    pid = @mock_process_manager.spawn("test-command")
    sigkill_sent = false

    # Keep process running until SIGKILL
    @mock_process_manager.running_hook = ->(check_pid) {
      !sigkill_sent && check_pid == pid
    }

    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      if signal == "KILL"
        sigkill_sent = true
      end
      1
    }

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )
    # Stub process_info
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: true, uid: Process.uid, state: "S" }
    end

    result = service.terminate

    assert result.success?
    assert sigkill_sent
    assert logged_messages.any? { |log| log[:content].include?("SIGKILL") }
  end

  # === Tests for error handling ===

  test "terminate handles unexpected errors gracefully" do
    pid = @mock_process_manager.spawn("test-command")

    @mock_process_manager.kill_hook = ->(signal, target_pid) {
      raise StandardError, "Unexpected error"
    }

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager
    )
    # Stub process_info
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: true, uid: Process.uid, state: "S" }
    end

    result = assert_nothing_raised { service.terminate }

    assert_not result.success?
    assert_equal :error, result.status
    assert_match(/Unexpected error/, result.message)
  end

  # === Tests for process ownership detection ===

  test "terminate logs warning when process has different owner" do
    pid = @mock_process_manager.spawn("test-command")

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = ProcessTerminationService.new(
      process_pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )

    # Stub process_info to return different owner
    service.define_singleton_method(:process_info) do
      { exists: true, is_zombie: false, owned_by_us: false, uid: 0, state: "S" }
    end

    service.terminate

    assert logged_messages.any? { |log| log[:level] == "warning" && log[:content].include?("different owner") }
  end

  test "terminate logs debug info when process owned by current user" do
    pid = @mock_process_manager.spawn("test-command")

    mock_buffer = Object.new
    logged_messages = []
    mock_buffer.define_singleton_method(:add) do |content, level: "info"|
      logged_messages << { content: content, level: level }
    end

    service = create_service_with_existing_process(
      pid: pid,
      process_manager: @mock_process_manager,
      log_buffer: mock_buffer
    )

    service.terminate

    assert logged_messages.any? { |log| log[:level] == "debug" && log[:content].include?("owned by current user") }
  end
end
