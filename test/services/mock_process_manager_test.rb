require "test_helper"

class MockProcessManagerTest < ActiveSupport::TestCase
  setup do
    # Using create_mock_process_manager helper from MockHelpers
    @manager = create_mock_process_manager
  end

  test "spawn records process information" do
    pid = @manager.spawn("echo", "test", chdir: "/tmp")

    # Using assert_process_spawned helper from AssertionHelpers
    assert_process_spawned(@manager, options: { chdir: "/tmp" })

    process_info = @manager.spawned_processes.first
    assert_equal pid, process_info[:pid]
    assert_equal [ "echo", "test" ], process_info[:command]
    assert_equal "/tmp", process_info[:options][:chdir]
  end

  test "spawn returns incrementing PIDs" do
    pid1 = @manager.spawn("echo", "1")
    pid2 = @manager.spawn("echo", "2")
    pid3 = @manager.spawn("echo", "3")

    assert_equal 10000, pid1
    assert_equal 10001, pid2
    assert_equal 10002, pid3
  end

  test "spawn calls spawn_hook if provided" do
    hook_called = false
    hook_command = nil
    hook_options = nil

    @manager.spawn_hook = ->(cmd, opts) {
      hook_called = true
      hook_command = cmd
      hook_options = opts
    }

    @manager.spawn("test", "command", foo: "bar")

    assert hook_called
    assert_equal [ "test", "command" ], hook_command
    assert_equal({ foo: "bar" }, hook_options)
  end

  test "wait returns mock status by default" do
    pid = @manager.spawn("echo", "test")

    result_pid, status = @manager.wait(pid)

    assert_equal pid, result_pid
    assert_kind_of MockProcessManager::MockStatus, status
    assert status.success?
  end

  test "wait calls wait_hook if provided" do
    hook_called = false
    @manager.wait_hook = ->(pid, flags) {
      hook_called = true
      [ pid, MockProcessManager::MockStatus.new(0) ]
    }

    @manager.wait(12345)

    assert hook_called
  end

  test "wait hook can return nil to simulate running process" do
    @manager.wait_hook = ->(pid, flags) { nil }

    result = @manager.wait(12345, Process::WNOHANG)

    assert_nil result
  end

  test "kill records signal and pid" do
    pid = @manager.spawn("echo", "test")

    @manager.kill("TERM", pid)

    # Using assert_process_killed helper from AssertionHelpers
    assert_process_killed(@manager, pid: pid, signal: "TERM")

    assert_equal 1, @manager.killed_processes.length

    kill_info = @manager.killed_processes.first
    assert_equal "TERM", kill_info[:signal]
    assert_equal pid, kill_info[:pid]
  end

  test "kill can be called multiple times" do
    pid = @manager.spawn("echo", "test")

    @manager.kill("TERM", pid)
    @manager.kill("KILL", pid)

    assert_equal 2, @manager.killed_processes.length
  end

  test "kill calls kill_hook if provided" do
    hook_called = false
    @manager.kill_hook = ->(signal, pid) {
      hook_called = true
    }

    @manager.kill("TERM", 12345)

    assert hook_called
  end

  test "running? returns true for spawned process" do
    pid = @manager.spawn("echo", "test")

    assert @manager.running?(pid)
  end

  test "running? returns false for killed process" do
    pid = @manager.spawn("echo", "test")
    @manager.kill("TERM", pid)

    assert_not @manager.running?(pid)
  end

  test "running? returns false for non-spawned process" do
    assert_not @manager.running?(99999)
  end

  test "running? returns true if kill signal was 0 (check only)" do
    pid = @manager.spawn("echo", "test")
    @manager.kill(0, pid) # Signal 0 just checks if process exists

    # Process should still be considered running
    assert @manager.running?(pid)
  end

  test "MockStatus success? returns true for exit code 0" do
    status = MockProcessManager::MockStatus.new(0)
    assert status.success?
  end

  test "MockStatus success? returns false for non-zero exit code" do
    status = MockProcessManager::MockStatus.new(1)
    assert_not status.success?
  end

  test "MockStatus exitstatus returns the exit code" do
    status = MockProcessManager::MockStatus.new(42)
    assert_equal 42, status.exitstatus
  end

  test "MockStatus to_i returns the exit code" do
    status = MockProcessManager::MockStatus.new(42)
    assert_equal 42, status.to_i
  end

  test "multiple processes can be tracked independently" do
    pid1 = @manager.spawn("echo", "1")
    pid2 = @manager.spawn("echo", "2")

    @manager.kill("TERM", pid1)

    assert_not @manager.running?(pid1)
    assert @manager.running?(pid2)
  end

  test "getpgid returns pid for running process" do
    pid = @manager.spawn("echo", "test")

    pgid = @manager.getpgid(pid)
    assert_equal pid, pgid
  end

  test "getpgid raises ESRCH for non-existent process" do
    assert_raises(Errno::ESRCH) do
      @manager.getpgid(99999)
    end
  end

  test "getpgid raises ESRCH for killed process" do
    pid = @manager.spawn("echo", "test")
    @manager.kill("TERM", pid)

    assert_raises(Errno::ESRCH) do
      @manager.getpgid(pid)
    end
  end

  # === Tests for spawn_with_tracking (Issue #326) ===

  test "spawn_with_tracking records process in registry" do
    pid = @manager.spawn_with_tracking("test-command", correlation_id: "abc123")

    info = @manager.get_tracked_process(pid)
    assert_not_nil info
    assert_equal pid, info[:pid]
    assert_equal "abc123", info[:correlation_id]
  end

  test "spawn_with_tracking tracks ownership" do
    pid = @manager.spawn_with_tracking("test-command")

    info = @manager.get_tracked_process(pid)
    assert_equal Process.uid, info[:uid]
    assert_equal Process.gid, info[:gid]
  end

  test "spawn_with_tracking records working directory" do
    pid = @manager.spawn_with_tracking("test", chdir: "/tmp")

    info = @manager.get_tracked_process(pid)
    assert_equal "/tmp", info[:working_directory]
  end

  test "spawn_with_tracking records process group with pgroup true" do
    pid = @manager.spawn_with_tracking("test", pgroup: true)

    info = @manager.get_tracked_process(pid)
    assert_equal pid, info[:process_group]
  end

  test "spawn_with_tracking generates correlation_id if not provided" do
    pid = @manager.spawn_with_tracking("test")

    info = @manager.get_tracked_process(pid)
    assert_not_nil info[:correlation_id]
  end

  # === Tests for kill_process_group (Issue #326) ===

  test "kill_process_group records group kill" do
    pid = @manager.spawn("test")

    @manager.kill_process_group("TERM", pid)

    kill_info = @manager.killed_processes.last
    assert_equal "TERM", kill_info[:signal]
    assert_equal(-pid.abs, kill_info[:pid])
    assert_equal :group, kill_info[:type]
  end

  test "kill_process_group calls kill_group_hook if provided" do
    hook_called = false
    hook_signal = nil
    hook_pgid = nil

    @manager.kill_group_hook = ->(signal, pgid) {
      hook_called = true
      hook_signal = signal
      hook_pgid = pgid
    }

    @manager.kill_process_group("KILL", 12345)

    assert hook_called
    assert_equal "KILL", hook_signal
    assert_equal 12345, hook_pgid
  end

  test "kill_process_group hook can raise ESRCH" do
    @manager.kill_group_hook = ->(signal, pgid) {
      raise Errno::ESRCH
    }

    assert_raises(Errno::ESRCH) do
      @manager.kill_process_group("TERM", 99999)
    end
  end

  # === Tests for tracked_processes (Issue #326) ===

  test "tracked_processes returns all tracked processes" do
    pid1 = @manager.spawn_with_tracking("test1")
    pid2 = @manager.spawn_with_tracking("test2")

    tracked = @manager.tracked_processes

    assert_equal 2, tracked.size
    assert tracked.key?(pid1)
    assert tracked.key?(pid2)
  end

  test "tracked_processes returns empty hash when none tracked" do
    tracked = @manager.tracked_processes

    assert_empty tracked
  end

  # === Tests for untrack_process (Issue #326) ===

  test "untrack_process removes process from tracking" do
    pid = @manager.spawn_with_tracking("test")

    removed = @manager.untrack_process(pid)

    assert_not_nil removed
    assert_nil @manager.get_tracked_process(pid)
  end

  test "untrack_process returns nil for untracked process" do
    removed = @manager.untrack_process(99999)

    assert_nil removed
  end

  # === Tests for wait integration with tracking (Issue #326) ===

  test "wait removes process from tracking" do
    pid = @manager.spawn_with_tracking("test")
    assert_not_nil @manager.get_tracked_process(pid)

    @manager.wait(pid)

    assert_nil @manager.get_tracked_process(pid)
  end

  # === Tests for set_process_gid (Issue #326) ===

  test "set_process_gid allows setting process group id" do
    pid = @manager.spawn("test")
    @manager.set_process_gid(pid, 20)

    info = @manager.mock_process_info(pid)
    assert_equal 20, info[:gid]
  end
end
