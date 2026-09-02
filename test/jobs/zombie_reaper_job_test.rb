# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "tmpdir"

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

  # === The hazard a pid-blind reap causes ===

  test "an untargeted reap steals a tracked child's exit status" do
    manager = SystemProcessManager.new
    pid = spawn_exiting_child(manager: manager, exit_code: 7)

    # `Process.waitpid(-1, …)` is the thing this job must never do. Reaping
    # blindly here consumes the status AgentSessionJob's monitoring loop needs to
    # route through handle_exit — the regression the tests below guard against.
    Process.waitpid(-1, Process::WNOHANG)

    assert_raises Errno::ECHILD do
      manager.wait(pid, Process::WNOHANG)
    end
  end

  test "a Process.detach waiter outside the registry keeps its status across a real confirmation delay" do
    # No stubbed sleep: this is the only protection an Open3/Process.detach wait
    # thread has, since nothing claims those pids in the registry.
    ZombieReaperJob.any_instance.unstub(:sleep)

    # An abandoned zombie guarantees the job takes the slow path rather than
    # returning early on an empty first pass.
    abandoned = spawn_exiting_child(manager: nil)
    detached = Process.spawn("sh", "-c", "exit 5")
    @spawned << detached
    wait_thr = Process.detach(detached)

    ZombieReaperJob.perform_now

    assert_not_nil wait_thr.value, "the reaper stole the detach thread's exit status"
    assert_equal 5, wait_thr.value.exitstatus
    assert_raises Errno::ECHILD, "the abandoned child was still collected" do
      Process.waitpid(abandoned, Process::WNOHANG)
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
    # this is how zombies accumulated in pulsemcp/pulsemcp#3549.
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

    assert_equal "alive", process_state(pid)
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

  test "keeps a claim for a candidate that turns out not to be reapable" do
    pid = spawn_exiting_child(manager: nil)
    # Stale enough not to be skipped, so the pid reaches the waitpid call.
    ChildWaiterRegistry.instance.heartbeat(
      pid,
      at: ChildWaiterRegistry.monotonic_now - ZombieReaperJob::LIVE_WAITER_STALE_AFTER - 1
    )
    # A nil return means the pid is alive after all — its real waiter collected
    # it and the number was recycled. The claim then belongs to a NEW process.
    Process.stubs(:waitpid).returns(nil)

    ZombieReaperJob.perform_now
    # Restore before teardown, which has a real child to collect.
    Process.unstub(:waitpid)

    assert_not_nil ChildWaiterRegistry.instance.waiter(pid),
      "a claim must not be dropped for a pid the job did not actually reap"
  end

  test "reports nothing to reap without raising an alarm" do
    ZombieChildScanner.any_instance.stubs(:snapshot).returns(
      ZombieChildScanner::Snapshot.new(pids: [ Process.pid ], zombie_child_pids: [])
    )
    logged = []
    Rails.logger.stubs(:info).with { |message| logged << [ :info, message ]; true }
    Rails.logger.stubs(:warn).with { |message| logged << [ :warn, message ]; true }

    ZombieReaperJob.perform_now

    assert_includes logged, [ :info, "[ZombieReaperJob] No zombies to reap" ]
    assert_empty logged.select { |level, message| level == :warn && message.include?("[ZombieReaperJob]") }
  end

  # === The other host-level leftover of a session's process tree (#815) ===

  # A session cannot always tear down its own memory cgroup: `rmdir` refuses while any pid
  # is still inside, and a worker killed mid-deploy never gets the chance. Nothing else
  # would ever remove them, and they arrive one per session.
  test "sweeps session memory cgroups that no longer hold a process" do
    ZombieChildScanner.any_instance.stubs(:snapshot).returns(
      ZombieChildScanner::Snapshot.new(pids: [ Process.pid ], zombie_child_pids: [])
    )

    with_delegated_cgroup_parent do |parent|
      finished = File.join(parent, "session-900")
      live = File.join(parent, "session-901")
      FileUtils.mkdir_p(finished)
      FileUtils.mkdir_p(live)
      File.write(File.join(live, "cgroup.procs"), "4242\n")

      ZombieReaperJob.perform_now

      refute File.directory?(finished)
      assert File.directory?(live), "a cgroup that still holds a process is a live session"
    end
  end

  # The sweep runs before the zombie passes and outside their early returns: "no zombies
  # this tick" is the common case, and it is not a reason to leave the cgroups behind.
  test "sweeps even when the process table cannot be read" do
    ZombieChildScanner.any_instance.stubs(:snapshot).returns(nil)

    with_delegated_cgroup_parent do |parent|
      FileUtils.mkdir_p(File.join(parent, "session-902"))

      ZombieReaperJob.perform_now

      refute File.directory?(File.join(parent, "session-902"))
    end
  end

  private

  def with_delegated_cgroup_parent
    original = ENV["ZIMMER_SESSION_CGROUP_ROOT"]
    Dir.mktmpdir("cgroupfs") do |tmp|
      parent = File.join(tmp, "zimmer.sessions")
      FileUtils.mkdir_p(parent)
      ENV["ZIMMER_SESSION_CGROUP_ROOT"] = parent
      yield parent
    end
  ensure
    original.nil? ? ENV.delete("ZIMMER_SESSION_CGROUP_ROOT") : ENV["ZIMMER_SESSION_CGROUP_ROOT"] = original
  end

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
      return if process_state(pid) == "defunct"
      raise "pid #{pid} never became defunct" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

  # "defunct" exited but unreaped, "alive" in the table and not defunct, "gone"
  # absent from the table entirely.
  def process_state(pid)
    state = `ps -o stat= -p #{pid}`.strip
    return "gone" if state.empty?
    state.start_with?("Z") ? "defunct" : "alive"
  end
end
