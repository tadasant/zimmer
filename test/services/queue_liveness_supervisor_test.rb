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

  test "the initializer does not start the watchdog in this (test) environment" do
    # config/initializers/queue_liveness_watchdog.rb gates on
    # AlertingEnvironments::ALL, which is production + staging only. The test suite
    # therefore never gets a real background thread from boot -- it drives the watchdog
    # directly -- so the initializer's env gate is what keeps this suite thread-free.
    assert_not_includes AlertingEnvironments::ALL, "test",
      "if test were an alerting environment the initializer would leak a thread into every run"
    assert_includes AlertingEnvironments::ALL, "production"
    assert_includes AlertingEnvironments::ALL, "staging"
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
