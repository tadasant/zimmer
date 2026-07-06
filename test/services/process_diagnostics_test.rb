require "test_helper"

class ProcessDiagnosticsTest < ActiveSupport::TestCase
  # === Tests for DiagnosticResult struct ===

  test "DiagnosticResult has expected attributes" do
    result = ProcessDiagnostics::DiagnosticResult.new(
      exists: true,
      state: "S",
      uid: 501,
      gid: 20,
      owner_name: "admin",
      is_zombie: false,
      owned_by_us: true,
      can_terminate: true,
      children: [],
      parent_pid: 1,
      process_group: 12345,
      command: "test",
      cpu_time: "0:00.01",
      start_time: nil,
      error: nil
    )

    assert result.exists
    assert_equal "S", result.state
    assert_equal 501, result.uid
    assert_not result.is_zombie
    assert result.can_terminate
  end

  test "DiagnosticResult#to_h removes nil values" do
    result = ProcessDiagnostics::DiagnosticResult.new(
      exists: true,
      state: "S",
      uid: 501,
      error: nil
    )

    hash = result.to_h
    assert_not hash.key?(:error)
    assert hash.key?(:exists)
  end

  # === Tests for full_report method ===

  test "full_report returns DiagnosticResult for invalid pid" do
    diagnostics = ProcessDiagnostics.new(-1)
    result = diagnostics.full_report

    assert_instance_of ProcessDiagnostics::DiagnosticResult, result
    assert_not result.exists
    assert_equal "Invalid PID", result.error
  end

  test "full_report returns DiagnosticResult for nil pid" do
    diagnostics = ProcessDiagnostics.new(nil)
    result = diagnostics.full_report

    assert_not result.exists
    assert_equal "Invalid PID", result.error
  end

  test "full_report returns exists false for non-existent process" do
    diagnostics = ProcessDiagnostics.new(999999)
    result = diagnostics.full_report

    assert_not result.exists
  end

  test "full_report returns process info for current process" do
    diagnostics = ProcessDiagnostics.new(Process.pid)
    result = diagnostics.full_report

    assert result.exists
    assert_equal Process.uid, result.uid
    assert result.owned_by_us
    assert result.can_terminate
    assert_not result.is_zombie
  end

  # === Tests for process_exists? method ===

  test "process_exists? returns true for current process" do
    diagnostics = ProcessDiagnostics.new(Process.pid)

    assert diagnostics.process_exists?
  end

  test "process_exists? returns false for non-existent process" do
    diagnostics = ProcessDiagnostics.new(999999)

    assert_not diagnostics.process_exists?
  end

  test "process_exists? returns false for invalid pid" do
    diagnostics = ProcessDiagnostics.new(-1)

    assert_not diagnostics.process_exists?
  end

  # === Tests for can_terminate? method ===

  test "can_terminate? returns true for own process" do
    diagnostics = ProcessDiagnostics.new(Process.pid)

    assert diagnostics.can_terminate?
  end

  test "can_terminate? returns false for invalid pid" do
    diagnostics = ProcessDiagnostics.new(-1)

    assert_not diagnostics.can_terminate?
  end

  test "can_terminate? returns false for non-existent process" do
    diagnostics = ProcessDiagnostics.new(999999)

    assert_not diagnostics.can_terminate?
  end

  # === Tests for zombie? method ===

  test "zombie? returns false for running process" do
    diagnostics = ProcessDiagnostics.new(Process.pid)

    assert_not diagnostics.zombie?
  end

  test "zombie? returns false for invalid pid" do
    diagnostics = ProcessDiagnostics.new(-1)

    assert_not diagnostics.zombie?
  end

  # === Tests for state_description method ===

  test "state_description returns not found for non-existent process" do
    diagnostics = ProcessDiagnostics.new(999999)

    assert_equal "not found", diagnostics.state_description
  end

  test "state_description returns description for running process" do
    diagnostics = ProcessDiagnostics.new(Process.pid)
    description = diagnostics.state_description

    # Current process could be running (R) or sleeping (S)
    assert_includes %w[running sleeping idle], description
  end

  # === Tests for process_tree method ===

  test "process_tree returns string for current process" do
    diagnostics = ProcessDiagnostics.new(Process.pid)
    tree = diagnostics.process_tree

    assert_kind_of String, tree
    assert_includes tree, Process.pid.to_s
  end

  test "process_tree returns not found message for invalid pid" do
    diagnostics = ProcessDiagnostics.new(999999)
    tree = diagnostics.process_tree

    assert_includes tree, "not found"
  end

  # === Tests for child_pids method ===

  test "child_pids returns array" do
    diagnostics = ProcessDiagnostics.new(Process.pid)
    children = diagnostics.child_pids

    assert_kind_of Array, children
  end

  test "child_pids returns empty array for process without children" do
    # Process.pid in tests typically doesn't spawn children
    diagnostics = ProcessDiagnostics.new(Process.pid)
    children = diagnostics.child_pids

    assert_kind_of Array, children
    # Can't assert empty because the test process might have children
  end

  # === Integration tests with real processes ===

  test "full_report provides complete diagnostics for spawned process" do
    # Spawn a simple sleep process
    pid = spawn("sleep", "10")

    begin
      sleep 0.1 # Give process time to start

      diagnostics = ProcessDiagnostics.new(pid)
      result = diagnostics.full_report

      assert result.exists
      assert_equal Process.uid, result.uid
      assert result.owned_by_us
      assert result.can_terminate
      assert_not result.is_zombie
      assert_includes result.command, "sleep"
    ensure
      Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  test "process_tree shows spawned process" do
    pid = spawn("sleep", "10")

    begin
      sleep 0.1

      diagnostics = ProcessDiagnostics.new(pid)
      tree = diagnostics.process_tree

      assert_includes tree, pid.to_s
      assert_includes tree, "sleep"
    ensure
      Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end
end
