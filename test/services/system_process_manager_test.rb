require "test_helper"

class SystemProcessManagerTest < ActiveSupport::TestCase
  setup do
    @manager = SystemProcessManager.new
  end

  # Spawn a short-lived process, wait for it to exit, and return its PID.
  # This PID is guaranteed to no longer be running (unlike a hardcoded PID
  # which can collide with real processes on busy CI runners).
  def dead_pid
    pid = @manager.spawn("true")
    @manager.wait(pid)
    pid
  end

  test "spawn creates a real process" do
    # Spawn a simple echo process that writes to a file
    output_file = Tempfile.new("test_output")
    output_file.close

    pid = @manager.spawn(
      "echo", "hello",
      out: output_file.path
    )

    assert_kind_of Integer, pid
    assert pid > 0

    # Wait for process to complete
    _, status = @manager.wait(pid)
    assert status.success?

    # Verify output
    assert_equal "hello\n", File.read(output_file.path)
  ensure
    output_file.unlink if output_file
  end

  test "wait returns nil for non-blocking check when process still running" do
    # Spawn a long-running process
    pid = @manager.spawn("sleep", "10")

    # Non-blocking wait should return nil while process is running
    result = @manager.wait(pid, Process::WNOHANG)
    assert_nil result

    # Clean up
    @manager.kill("TERM", pid)
    @manager.wait(pid)
  end

  test "wait returns pid and status when process completes" do
    pid = @manager.spawn("echo", "test", out: File::NULL)

    # Wait for completion
    result_pid, status = @manager.wait(pid)

    assert_equal pid, result_pid
    assert_kind_of Process::Status, status
    assert status.success?
  end

  test "kill sends signal to process" do
    # Spawn a long-running process
    pid = @manager.spawn("sleep", "60")

    # Kill the process
    assert_equal 1, @manager.kill("TERM", pid)

    # Wait for process to be reaped
    _, status = @manager.wait(pid)
    # SIGTERM typically results in exit code 143 (128 + 15)
    # But this can vary, so just check that the process was terminated
    assert status, "Process status should be available"
    assert_not status.success?, "Process should not exit successfully after SIGTERM"
  end

  test "running? returns true for running process" do
    pid = @manager.spawn("sleep", "10")

    assert @manager.running?(pid)

    # Clean up
    @manager.kill("KILL", pid)
    @manager.wait(pid)
  end

  test "running? returns false for non-existent process" do
    assert_not @manager.running?(dead_pid)
  end

  test "running? returns false after process exits" do
    pid = @manager.spawn("echo", "test", out: File::NULL)

    # Wait for process to complete
    @manager.wait(pid)

    # Process should no longer be running
    assert_not @manager.running?(pid)
  end

  test "running? returns false for nil pid" do
    assert_not @manager.running?(nil)
  end

  test "spawn with chdir option changes working directory" do
    temp_dir = Dir.mktmpdir
    test_file = File.join(temp_dir, "test.txt")
    File.write(test_file, "content")

    output_file = Tempfile.new("test_output")
    output_file.close

    pid = @manager.spawn(
      "ls",
      chdir: temp_dir,
      out: output_file.path
    )

    @manager.wait(pid)

    # Should see test.txt in the output
    output = File.read(output_file.path)
    assert_includes output, "test.txt"
  ensure
    FileUtils.rm_rf(temp_dir) if temp_dir
    output_file.unlink if output_file
  end

  test "spawn with pgroup creates new process group" do
    pid = @manager.spawn("sleep", "10", pgroup: true)

    # Process should be in its own process group
    assert_equal pid, @manager.getpgid(pid)

    # Clean up
    @manager.kill("TERM", -pid) # Kill entire process group
    @manager.wait(pid) rescue Errno::ECHILD
  end

  test "getpgid returns process group ID" do
    pid = @manager.spawn("sleep", "10", pgroup: true)

    pgid = @manager.getpgid(pid)
    assert_kind_of Integer, pgid
    assert_equal pid, pgid # With pgroup: true, pgid should equal pid

    # Clean up
    @manager.kill("KILL", pid)
    @manager.wait(pid)
  end

  test "getpgid raises ESRCH for non-existent process" do
    assert_raises(Errno::ESRCH) do
      @manager.getpgid(dead_pid)
    end
  end
end
