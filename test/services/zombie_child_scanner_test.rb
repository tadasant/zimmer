# frozen_string_literal: true

require "test_helper"

class ZombieChildScannerTest < ActiveSupport::TestCase
  PS_OUTPUT = <<~PS
        1       0 Ss
      100       1 Sl
      101     100 Z
      102     100 S
      103     999 Z
      104     100 Z+
  PS

  def scanner(output: PS_OUTPUT, ok: true, parent_pid: 100)
    ZombieChildScanner.new(parent_pid: parent_pid, ps_runner: -> { [ output, ok ] })
  end

  test "reports every pid in the table" do
    assert_equal [ 1, 100, 101, 102, 103, 104 ], scanner.snapshot.pids.sort
  end

  test "reports only zombies that are our own direct children" do
    zombies = scanner.snapshot.zombie_child_pids.sort

    assert_equal [ 101, 104 ], zombies
    assert_not_includes zombies, 103, "103 is a zombie but belongs to another parent"
    assert_not_includes zombies, 102, "102 is our child but is not defunct"
  end

  test "returns nil when ps fails so the caller reaps nothing" do
    assert_nil scanner(output: nil, ok: false).snapshot
  end

  test "ignores header or garbage lines" do
    snapshot = scanner(output: "  PID  PPID STAT\n  101   100 Z\n\n").snapshot

    assert_equal [ 101 ], snapshot.pids
    assert_equal [ 101 ], snapshot.zombie_child_pids
  end

  test "reads the real process table and finds a real zombie child" do
    pid = Process.spawn("true")
    wait_until_defunct(pid)

    snapshot = ZombieChildScanner.new.snapshot

    assert_not_nil snapshot, "ps should be readable in the test environment"
    assert_includes snapshot.pids, Process.pid
    assert_includes snapshot.zombie_child_pids, pid
  ensure
    begin
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
  end

  private

  def wait_until_defunct(pid, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      state = `ps -o stat= -p #{pid}`.strip
      break if state.start_with?("Z")
      raise "pid #{pid} never became defunct" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end
end
