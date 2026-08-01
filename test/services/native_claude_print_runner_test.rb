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
  # land in @reaped, which is what "the child was reaped" is asserted against.
  def stall_until_timeout(&collected_when)
    @pm.wait_hook = lambda do |pid, flags|
      unless flags == Process::WNOHANG
        sleep 5 # interrupted by Timeout.timeout in #run
        next [ pid, MockProcessManager::MockStatus.new(0) ]
      end

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
  end

  test "raises without spawning when the prompt is blank" do
    assert_raises(NativeClaudePrintRunner::Error) { build_runner.run(prompt: "  ", timeout: 5) }
    assert_empty @pm.spawned_processes
  end

  # The defect in #281: before this fix, teardown sent SIGTERM and returned, so
  # nothing ever waited on the pid again and the child sat defunct until
  # ZombieReaperJob's next tick.
  test "reaps the child before run returns when the call times out" do
    stall_until_timeout { terminated?("TERM") }

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert terminated?("TERM"), "expected SIGTERM"
    refute terminated?("KILL"), "should not escalate when SIGTERM is honored"
    assert_equal [ @pm.spawned_processes.first[:pid] ], @reaped, "child should have been collected"
    assert_empty @logger.warnings
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
    assert_operator elapsed, :<, 2.0, "teardown must stay bounded, took #{elapsed}s"
    assert_equal 1, @logger.warnings.size
    assert_match(/still not collected after SIGKILL/, @logger.warnings.first)
  end

  test "treats ECHILD as collected when something else reaped the child first" do
    @pm.wait_hook = lambda do |_pid, flags|
      raise Errno::ECHILD if flags == Process::WNOHANG
      sleep 5
    end

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert terminated?("TERM")
    refute terminated?("KILL"), "an already-reaped child needs no SIGKILL"
    assert_empty @logger.warnings
  end

  test "tolerates a child that exits between the timeout and the signal" do
    @pm.kill_hook = ->(_signal, _pid) { raise Errno::ESRCH }
    stall_until_timeout { true }

    assert_raises(Timeout::Error) { build_runner.run(prompt: "hi", timeout: 0.05) }

    assert_empty @logger.warnings
  end

  test "logs rather than masking the timeout when teardown itself fails" do
    @pm.kill_hook = ->(_signal, _pid) { raise Errno::EPERM }
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
