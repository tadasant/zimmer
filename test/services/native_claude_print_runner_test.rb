# frozen_string_literal: true

require "test_helper"

# Drives the native `claude -p` backend through its injected process manager.
#
# The interesting half is the timeout path: `Timeout` unwinds the only blocking
# `wait`, so teardown owns the reap. These tests pin that the child is collected
# before `run` returns, and — the constraint that makes it non-trivial — that a
# child which ignores SIGTERM never blocks the caller.
class NativeClaudePrintRunnerTest < ActiveSupport::TestCase
  # Captures warn lines without touching Rails.logger.
  class CapturingLogger
    attr_reader :warnings

    def initialize = @warnings = []
    def warn(message) = @warnings << message.to_s
  end

  setup do
    @pm = MockProcessManager.new
    @logger = CapturingLogger.new
    @reaped = [] # pids the runner actually collected, in order
  end

  # Builds a runner with a tiny reap window so the bounded-poll tests cost
  # milliseconds rather than seconds. Production defaults live in the constants.
  def build_runner(**overrides)
    NativeClaudePrintRunner.new(
      claude_binary: "/fake/claude",
      model: "haiku",
      process_manager: @pm,
      logger: @logger,
      reap_window: 0.05,
      reap_poll_interval: 0.005,
      **overrides
    )
  end

  # The mock never runs anything, so stand in for the child's stdout by writing
  # the file the runner told `spawn` to redirect into.
  def write_output_on_spawn(text)
    @pm.spawn_hook = ->(_args, options) { File.write(options[:out].first, text) }
  end

  # A child that stays alive: the blocking wait sleeps past the run's timeout,
  # and every WNOHANG poll answers according to `collected_when`. Collected pids
  # land in @reaped, which is what "the child was reaped" is asserted against;
  # polling a pid already collected raises ECHILD, as Process.wait2 does.
  def stall_until_timeout(&collected_when)
    @pm.wait_hook = lambda do |pid, flags|
      next sleep(5) unless flags == Process::WNOHANG # sleep is unwound by Timeout in #run

      raise Errno::ECHILD if @reaped.include?(pid)
      next nil unless collected_when.call

      @reaped << pid
      [ pid, MockProcessManager::MockStatus.signaled(15) ]
    end
  end

  def terminated?(signal)
    @pm.killed_processes.any? { |k| k[:signal] == signal }
  end

  test "returns the child's stdout on the happy path" do
    write_output_on_spawn("a title\n")

    result = build_runner.run(prompt: "name this", timeout: 5)

    assert_equal "a title\n", result.text
    assert_nil result.usage
    assert_equal [ "/fake/claude", "--dangerously-skip-permissions", "--model", "haiku", "-p", "name this" ],
      @pm.spawned_processes.first[:command]
    assert_empty @pm.killed_processes, "a child that completes on time is never signalled"
  end

  test "raises without spawning when the prompt is blank" do
    assert_raises(NativeClaudePrintRunner::Error) { build_runner.run(prompt: "  ", timeout: 5) }
    assert_empty @pm.spawned_processes
  end

  # Regression guard for #281: teardown must not signal and return. Nothing else
  # waits on the pid, so a child left unsignalled-for sits defunct until
  # ZombieReaperJob's next tick.
  test "reaps the child before run returns when the call times out" do
    stall_until_timeout { terminated?("TERM") }

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert terminated?("TERM"), "expected SIGTERM"
    refute terminated?("KILL"), "should not escalate when SIGTERM is honored"
    assert_equal [ @pm.spawned_processes.first[:pid] ], @reaped, "child should have been collected"
    assert_empty @logger.warnings
  end

  # The window is what separates this from "SIGTERM, then SIGKILL immediately":
  # a child that takes a few hundred milliseconds to die is still collected on
  # the first signal.
  test "keeps polling within the window rather than escalating on the first miss" do
    polls = 0
    stall_until_timeout { (polls += 1) >= 4 }

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert_operator polls, :>=, 4, "the reap must poll repeatedly, not check once"
    refute terminated?("KILL"), "the child died inside the SIGTERM window"
    assert_equal [ @pm.spawned_processes.first[:pid] ], @reaped
  end

  test "escalates to SIGKILL and reaps a child that ignores SIGTERM" do
    stall_until_timeout { terminated?("KILL") }

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert terminated?("TERM"), "expected SIGTERM first"
    assert terminated?("KILL"), "expected escalation to SIGKILL"
    assert_equal [ @pm.spawned_processes.first[:pid] ], @reaped, "child should have been collected"
    assert_empty @logger.warnings
  end

  # The bound is the point: a child that answers no signal must not hold the
  # caller (a GoodJob worker thread) open.
  test "does not block the caller on a child that ignores every signal" do
    stall_until_timeout { false }
    runner = build_runner(reap_window: 0.1, reap_poll_interval: 0.01)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Timeout::Error) { runner.run(prompt: "hi", timeout: 0.05) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert terminated?("TERM")
    assert terminated?("KILL")
    assert_empty @reaped, "the child never exited, so nothing was collected"
    assert_operator elapsed, :>=, 0.2, "both reap windows must be waited out, took #{elapsed}s"
    assert_operator elapsed, :<, 2.0, "teardown must stay bounded, took #{elapsed}s"
    assert_equal 1, @logger.warnings.size
    assert_match(/still not collected after SIGKILL/, @logger.warnings.first)
  end

  # Timeout delivers its exception at the next safe point, so the blocking wait
  # can already have collected the child: the signal then finds nothing (ESRCH)
  # and the poll after it confirms the collection.
  test "settles quietly when the blocking wait already collected the child" do
    @pm.kill_hook = ->(_signal, _pid) { raise Errno::ESRCH }
    @pm.wait_hook = lambda do |pid, flags|
      next [ pid, MockProcessManager::MockStatus.new(0) ] if flags == Process::WNOHANG
      sleep 5
    end

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    refute terminated?("KILL"), "an already-collected child needs no escalation"
    assert_empty @logger.warnings
  end

  # ZombieReaperJob's blanket `waitpid(-1)` can win the race mid-reap; ECHILD is
  # how that reaches us.
  test "treats ECHILD as collected when something else reaps the child first" do
    polls = 0
    @pm.wait_hook = lambda do |_pid, flags|
      next sleep(5) unless flags == Process::WNOHANG
      polls += 1
      raise Errno::ECHILD if polls > 1

      nil # still ours, still running, at the pre-signal check
    end

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert terminated?("TERM")
    refute terminated?("KILL"), "an already-reaped child needs no SIGKILL"
    assert_empty @logger.warnings
  end

  test "tolerates ESRCH from the signal" do
    @pm.kill_hook = ->(_signal, _pid) { raise Errno::ESRCH }
    polls = 0
    @pm.wait_hook = lambda do |_pid, flags|
      next sleep(5) unless flags == Process::WNOHANG
      polls += 1
      raise Errno::ECHILD if polls > 1 # ESRCH means the pid is gone, so it is already reaped

      nil
    end

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert terminated?("TERM")
    refute terminated?("KILL")
    assert_empty @logger.warnings
  end

  # A signal we are not allowed to send is not a reason to skip the reap: the
  # child may already be a collectable zombie.
  test "still reaps when the signal is refused with EPERM" do
    @pm.kill_hook = ->(_signal, _pid) { raise Errno::EPERM }
    stall_until_timeout { terminated?("TERM") }

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert_equal [ @pm.spawned_processes.first[:pid] ], @reaped, "child should still have been collected"
    assert_equal 1, @logger.warnings.size
    assert_match(/cannot send SIGTERM/, @logger.warnings.first)
  end

  test "logs rather than masking the timeout when teardown itself fails" do
    @pm.kill_hook = ->(_signal, _pid) { raise "process manager exploded" }
    stall_until_timeout { false }

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert_equal 1, @logger.warnings.size
    assert_match(/failed to terminate process/, @logger.warnings.first)
  end

  test "removes the temp directory on both the happy path and the timeout path" do
    dirs = []
    @pm.spawn_hook = lambda do |_args, options|
      dirs << options[:chdir]
      File.write(options[:out].first, "ok")
    end

    build_runner.run(prompt: "hi", timeout: 5)

    stall_until_timeout { terminated?("TERM") }
    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert_equal 2, dirs.size
    dirs.each { |dir| refute Dir.exist?(dir), "expected #{dir} to be cleaned up" }
  end
end
