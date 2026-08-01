# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# These tests spawn REAL children and let them become REAL zombies. The bug this
# job exists to avoid (#273) is a race between two waiters inside one process, and
# a mocked process table cannot demonstrate that a specific exit status survived.
class ZombieReaperJobTest < ActiveJob::TestCase
  setup do
    ChildWaiterRegistry.reset!
    # The confirmation delay only has to outlast a Process.detach thread's reap;
    # the two passes still run in order without really sleeping.
    ZombieReaperJob.any_instance.stubs(:sleep)
    @spawned = []
  end

  teardown do
    @spawned.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    @spawned.each do |pid|
      Process.waitpid(pid)
    rescue Errno::ECHILD
      nil
    end
    ChildWaiterRegistry.reset!
  end

  # === The hazard this job used to cause ===

  test "the untargeted reap this job used to do steals a tracked child's exit status" do
    manager = SystemProcessManager.new
    pid = spawn_exiting_child(manager: manager, exit_code: 7)

    # Verbatim what the old implementation did.
    Process.waitpid(-1, Process::WNOHANG)

    assert_raises Errno::ECHILD, "the old reaper consumed the status the monitoring loop needed" do
      manager.wait(pid, Process::WNOHANG)
    end
  end

  # === What the pid-aware job does instead ===

  test "leaves a defunct child alone while its waiter is still checking in" do
    manager = SystemProcessManager.new
    pid = spawn_exiting_child(manager: manager, exit_code: 7)

    ZombieReaperJob.perform_now

    # The exit status is still ours to collect — i.e. AgentSessionJob's
    # wait_nonblock still routes through handle_exit instead of falling through
    # to signal-based detection and a bare session.pause!.
    result = manager.wait(pid, Process::WNOHANG)

    assert_not_nil result, "the reaper must not consume a live waiter's exit status"
    assert_equal pid, result[0]
    assert_equal 7, result[1].exitstatus
  end

  test "reaps a defunct child nothing is waiting on" do
    pid = spawn_exiting_child(manager: nil)

    assert_not ChildWaiterRegistry.instance.live?(pid, stale_after: ZombieReaperJob::LIVE_WAITER_STALE_AFTER)

    ZombieReaperJob.perform_now

    assert_raises Errno::ECHILD, "an abandoned zombie must still be collected" do
      Process.waitpid(pid, Process::WNOHANG)
    end
  end

  test "reaps a defunct child whose waiter died without reaping it" do
    manager = SystemProcessManager.new
    pid = spawn_exiting_child(manager: manager, exit_code: 0)

    # Simulate the waiter going away: the claim is still there, but nothing has
    # called wait on it for longer than the staleness window. Left unhandled,
    # this is how zombies accumulated in tadasant/zimmer-catalog#3549.
    ChildWaiterRegistry.instance.heartbeat(
      pid,
      at: ChildWaiterRegistry.monotonic_now - ZombieReaperJob::LIVE_WAITER_STALE_AFTER - 1
    )

    ZombieReaperJob.perform_now

    assert_raises Errno::ECHILD, "an orphaned claim must not shield a zombie forever" do
      Process.waitpid(pid, Process::WNOHANG)
    end
    assert_nil ChildWaiterRegistry.instance.waiter(pid), "the orphaned claim should be dropped once reaped"
  end

  test "reaps the abandoned child and spares the watched one in the same tick" do
    manager = SystemProcessManager.new
    watched = spawn_exiting_child(manager: manager, exit_code: 3)
    abandoned = spawn_exiting_child(manager: nil)

    ZombieReaperJob.perform_now

    result = manager.wait(watched, Process::WNOHANG)
    assert_not_nil result, "the watched child's status survived"
    assert_equal 3, result[1].exitstatus

    assert_raises Errno::ECHILD, "the abandoned child was still collected" do
      Process.waitpid(abandoned, Process::WNOHANG)
    end
  end

  test "does not touch a child that is still running" do
    manager = SystemProcessManager.new
    pid = manager.spawn("sleep", "30")
    @spawned << pid

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ZombieReaperJob.perform_now
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal "R", process_state(pid)
    assert elapsed < 5.0, "ZombieReaperJob took #{elapsed}s — it must never block on a live child"
  end

  test "does not raise when this process has no children at all" do
    assert_nothing_raised { ZombieReaperJob.perform_now }
  end

  # === Failure modes ===

  test "reaps nothing when the process table cannot be read" do
    pid = spawn_exiting_child(manager: nil)
    ZombieChildScanner.any_instance.stubs(:snapshot).returns(nil)

    ZombieReaperJob.perform_now

    assert_equal pid, Process.waitpid(pid, Process::WNOHANG),
      "an unreadable process table must mean 'reap nothing', not 'reap everything'"
  end

  test "reaps nothing when the second pass cannot be read" do
    pid = spawn_exiting_child(manager: nil)
    first = ZombieChildScanner.new.snapshot
    ZombieChildScanner.any_instance.stubs(:snapshot).returns(first, nil)

    ZombieReaperJob.perform_now

    assert_equal pid, Process.waitpid(pid, Process::WNOHANG)
  end

  test "only reaps pids that were defunct on both passes" do
    pid = spawn_exiting_child(manager: nil)
    first = ZombieChildScanner.new.snapshot
    second = ZombieChildScanner::Snapshot.new(
      pids: first.pids,
      zombie_child_pids: first.zombie_child_pids - [ pid ]
    )
    ZombieChildScanner.any_instance.stubs(:snapshot).returns(first, second)

    ZombieReaperJob.perform_now

    assert_equal pid, Process.waitpid(pid, Process::WNOHANG),
      "a child that stopped being defunct between passes had a waiter and must be left alone"
  end

  test "prunes claims for pids that no longer exist" do
    ChildWaiterRegistry.instance.claim(999_999)

    ZombieReaperJob.perform_now

    assert_nil ChildWaiterRegistry.instance.waiter(999_999)
  end

  test "says nothing alarming when there is nothing to reap" do
    ZombieChildScanner.any_instance.stubs(:snapshot).returns(
      ZombieChildScanner::Snapshot.new(pids: [ Process.pid ], zombie_child_pids: [])
    )
    Rails.logger.stubs(:info)
    Rails.logger.expects(:warn).never

    ZombieReaperJob.perform_now
  end

  private

  # Spawn a child that exits immediately, then wait for it to actually become
  # defunct. With `manager`, the spawn goes through SystemProcessManager so the
  # pid is claimed in ChildWaiterRegistry exactly the way a real session's is.
  def spawn_exiting_child(manager:, exit_code: 0)
    args = [ "sh", "-c", "exit #{exit_code}" ]
    pid = manager ? manager.spawn(*args) : Process.spawn(*args)
    @spawned << pid
    wait_until_defunct(pid)
    pid
  end

  def wait_until_defunct(pid, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if process_state(pid) == "Z"
      raise "pid #{pid} never became defunct" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  # "Z" defunct, "R" present and not defunct, "-" gone from the table entirely.
  def process_state(pid)
    state = `ps -o stat= -p #{pid}`.strip
    return "-" if state.empty?
    state.start_with?("Z") ? "Z" : "R"
  end
end
