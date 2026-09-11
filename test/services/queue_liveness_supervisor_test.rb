# frozen_string_literal: true

require "test_helper"
require "timeout"

# The thread manager. It must start exactly one immortal thread, tick the watchdog on
# its interval, and stop cooperatively -- the properties that let it be the one liveness
# path that keeps running when the queue does not.
class QueueLivenessSupervisorTest < ActiveSupport::TestCase
  teardown do
    # Never leak a background thread across tests.
    QueueLivenessSupervisor.stop!
  end

  # A watchdog whose check! we can observe without a database.
  class RecordingWatchdog
    attr_reader :calls

    def initialize
      @calls = Queue.new
    end

    def check!
      @calls << true
      :healthy
    end
  end

  # The initializer's whole gate, exercised from a process that is none of the things it
  # asks about. This is the highest-blast-radius test in the file: if the gate silently
  # stops being true, Zimmer is back in the #427 hole with no log line and no failure.
  test "should_start? is true only in a web server process in an alerting environment" do
    assert QueueLivenessSupervisor.should_start?(server: true, env: "production", disabled: nil)
    assert QueueLivenessSupervisor.should_start?(server: true, env: "staging", disabled: nil)
  end

  test "should_start? is false outside the web server process" do
    # The worker runs `good_job start`, rake/console/runner and agent sessions run
    # neither -- none of them defines Rails::Server. The worker is the failure domain
    # this exists to escape, so a thread there would buy nothing.
    assert_not QueueLivenessSupervisor.should_start?(server: false, env: "production", disabled: nil)
  end

  test "should_start? is false outside the alerting environments" do
    # Development runs GoodJob `:async` inside Puma, so the web IS the worker and the
    # out-of-band property does not exist; test drives the watchdog directly. This is
    # also what keeps a real background thread out of every suite run.
    assert_not QueueLivenessSupervisor.should_start?(server: true, env: "development", disabled: nil)
    assert_not QueueLivenessSupervisor.should_start?(server: true, env: "test", disabled: nil)
    assert_not_includes AlertingEnvironments::ALL, "test"
  end

  test "should_start? honours the escape hatch" do
    assert_not QueueLivenessSupervisor.should_start?(server: true, env: "production", disabled: "true")
    # Only the exact string disables it, so a stray value cannot silently switch the
    # watchdog off.
    assert QueueLivenessSupervisor.should_start?(server: true, env: "production", disabled: "false")
    assert QueueLivenessSupervisor.should_start?(server: true, env: "production", disabled: "1")
  end

  test "should_start? defaults report this process, which is not a web server" do
    assert_not QueueLivenessSupervisor.should_start?,
      "the suite must never satisfy the gate, or boot would leak a thread into every run"
  end

  test "the interval is read through ConnectionBudget.int_env" do
    # Evaluated at eager-load, so a malformed value takes the web container down before
    # it can pass a health check. int_env treats blank as absent (Kamal renders an unset
    # env: clear: variable to ""), parses base 10, and refuses a non-positive value.
    assert_equal 60, QueueLivenessSupervisor::DEFAULT_INTERVAL_SECONDS
    assert_equal 60, ConnectionBudget.int_env("QUEUE_LIVENESS_WATCHDOG_INTERVAL_SECONDS_ABSENT", 60)
    assert_raises(ArgumentError) do
      ENV["QLW_TEST_INTERVAL"] = "0"
      ConnectionBudget.int_env("QLW_TEST_INTERVAL", 60)
    ensure
      ENV.delete("QLW_TEST_INTERVAL")
    end
  end

  test "start! returns a live thread and reports running?" do
    thread = QueueLivenessSupervisor.start!(interval: 60, watchdog: RecordingWatchdog.new)
    assert_kind_of Thread, thread
    assert thread.alive?
    assert QueueLivenessSupervisor.running?
  end

  test "start! is idempotent while a thread is already alive" do
    first = QueueLivenessSupervisor.start!(interval: 60, watchdog: RecordingWatchdog.new)
    second = QueueLivenessSupervisor.start!(interval: 60, watchdog: RecordingWatchdog.new)
    assert_same first, second, "a second start! must not spawn a new thread"
  end

  test "the started thread ticks the watchdog on its interval" do
    watchdog = RecordingWatchdog.new
    QueueLivenessSupervisor.start!(interval: 0.01, watchdog: watchdog)
    Timeout.timeout(5) { watchdog.calls.pop }
    assert true, "thread invoked check! at least once"
  end

  test "a raising tick does not kill the supervising thread" do
    # The watchdog rescues its own read failures, but the supervisor double-guards: a
    # thread that dies on an unexpected raise would silently remove the one liveness
    # path this whole change exists to keep alive.
    exploder = Object.new
    calls = Queue.new
    exploder.define_singleton_method(:check!) do
      calls << true
      raise "boom"
    end

    QueueLivenessSupervisor.start!(interval: 0.01, watchdog: exploder)
    # It keeps ticking despite every tick raising: pop twice proves it survived the
    # first raise to make a second call.
    Timeout.timeout(5) do
      calls.pop
      calls.pop
    end
    assert QueueLivenessSupervisor.running?, "the thread must survive a raising tick"
  end

  test "stop! terminates the background thread" do
    QueueLivenessSupervisor.start!(interval: 60, watchdog: RecordingWatchdog.new)
    assert QueueLivenessSupervisor.running?

    assert_equal true, QueueLivenessSupervisor.stop!
    refute QueueLivenessSupervisor.running?
  end

  test "stop! reports failure and keeps its handle when a tick outlasts the join" do
    # Dropping the handles would make running? lie while a thread is still alive. The
    # event stays set, so the thread exits as soon as its tick returns.
    started = Queue.new
    release = Queue.new

    slow = Object.new
    slow.define_singleton_method(:check!) do
      started << true
      release.pop
      :healthy
    end

    first = QueueLivenessSupervisor.start!(interval: 0.01, watchdog: slow)
    Timeout.timeout(10) { started.pop }

    assert_equal false, QueueLivenessSupervisor.stop!(timeout: 0.1),
      "stop! must report that the thread outlasted the join"
    assert QueueLivenessSupervisor.running?,
      "running? must not claim the thread is gone while it is still alive"

    # And start! must NOT adopt that dying thread: its stop event is already set, so it
    # would exit the moment its tick returned and the process would silently have no
    # watchdog at all.
    second = QueueLivenessSupervisor.start!(interval: 60, watchdog: RecordingWatchdog.new)
    assert_not_same first, second,
      "start! must build a fresh thread rather than adopt one that is already stopping"
    assert QueueLivenessSupervisor.running?
  ensure
    release << true
  end

  test "a tick runs inside the Rails executor so it returns its database connection" do
    # Without executor.wrap the thread leases a connection out of the web's five-slot
    # pool and never gives it back. Pin it with a tick that really touches the database,
    # then assert the thread owns no pooled connection once it has stopped.
    ticked = Queue.new

    toucher = Object.new
    toucher.define_singleton_method(:check!) do
      GoodJob::Job.count
      ticked << true
      :healthy
    end

    thread = QueueLivenessSupervisor.start!(interval: 0.01, watchdog: toucher)
    Timeout.timeout(10) { ticked.pop }
    QueueLivenessSupervisor.stop!

    assert_not ActiveRecord::Base.connection_pool.connections.any? { |conn| conn.owner == thread },
      "the watchdog thread must not still own a pooled connection after its tick"
  end

  test "stop! lets an in-flight tick finish instead of killing the thread" do
    # The tick talks to the database, so an asynchronous kill can return a
    # half-configured connection to the pool. Stopping is cooperative, which means an
    # in-flight tick runs to completion.
    started = Queue.new
    finished = Concurrent::AtomicBoolean.new(false)

    slow = Object.new
    slow.define_singleton_method(:check!) do
      started << true
      sleep 0.3
      finished.make_true
      :healthy
    end

    QueueLivenessSupervisor.start!(interval: 0.01, watchdog: slow)
    Timeout.timeout(10) { started.pop }
    QueueLivenessSupervisor.stop!

    assert finished.true?, "stop! must not abort a tick that is already running"
    assert_not QueueLivenessSupervisor.running?
  end
end
