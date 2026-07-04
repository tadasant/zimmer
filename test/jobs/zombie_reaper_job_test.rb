# frozen_string_literal: true

require "test_helper"

class ZombieReaperJobTest < ActiveJob::TestCase
  test "swallows ECHILD when there are no children to reap" do
    # No setup — just call the job in a process state with no children.
    # If it bubbled the exception this would fail.
    assert_nothing_raised do
      ZombieReaperJob.perform_now
    end
  end

  test "reaps a real zombie subprocess" do
    # Spawn a child that exits immediately. Without waitpid, it becomes
    # a zombie. The job should reap it.
    pid = Process.spawn("true")
    # Give the child time to exit and become a zombie.
    sleep 0.05

    ZombieReaperJob.perform_now

    # If the zombie was reaped, waitpid should now raise ECHILD (no such
    # child). If not reaped, it would either return the pid or block.
    assert_raises(Errno::ECHILD) do
      Process.waitpid(pid, Process::WNOHANG)
    end
  end

  test "does not block on still-running children" do
    # Spawn a long-running child.
    pid = Process.spawn("sleep", "10")

    # The job should return quickly even though the child is still running,
    # because we use WNOHANG.
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ZombieReaperJob.perform_now
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert elapsed < 1.0, "ZombieReaperJob blocked for #{elapsed}s — should be near-instant"

    # Cleanup: kill and reap the still-running child so it doesn't leak
    # across tests.
    Process.kill("KILL", pid)
    Process.waitpid(pid)
  end
end
