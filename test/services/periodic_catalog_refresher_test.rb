# frozen_string_literal: true

require "test_helper"
require "timeout"

class PeriodicCatalogRefresherTest < ActiveSupport::TestCase
  teardown do
    # Never leak a background thread across tests.
    PeriodicCatalogRefresher.stop!
  end

  test "refresh_once invokes AirCatalogService.refresh!" do
    called = false
    AirCatalogService.stub(:refresh!, -> { called = true; true }) do
      PeriodicCatalogRefresher.refresh_once
    end
    assert called, "refresh_once should call AirCatalogService.refresh!"
  end

  test "refresh_once swallows errors so the supervising thread survives" do
    AirCatalogService.stub(:refresh!, -> { raise AirCatalogService::CatalogError, "boom" }) do
      assert_nothing_raised do
        PeriodicCatalogRefresher.refresh_once
      end
    end
  end

  test "start! returns a live thread and reports running?" do
    AirCatalogService.stub(:refresh!, -> { true }) do
      thread = PeriodicCatalogRefresher.start!(interval: 60)
      assert_kind_of Thread, thread
      assert thread.alive?
      assert PeriodicCatalogRefresher.running?
    end
  end

  test "start! is idempotent while a thread is already alive" do
    AirCatalogService.stub(:refresh!, -> { true }) do
      first = PeriodicCatalogRefresher.start!(interval: 60)
      second = PeriodicCatalogRefresher.start!(interval: 60)
      assert_same first, second, "a second start! must not spawn a new thread"
    end
  end

  test "stop! lets an in-flight refresh finish instead of killing the thread" do
    # refresh_once talks to the database (AirCatalogService persists a catalog
    # snapshot). Thread#kill lands at an arbitrary point inside ActiveRecord and can
    # return a half-configured connection to the pool — zimmer#706. Stopping has to
    # be cooperative, which means an in-flight refresh runs to completion.
    started = Queue.new
    finished = Concurrent::AtomicBoolean.new(false)

    AirCatalogService.stub(:refresh!, lambda {
      started << true
      sleep 0.3
      finished.make_true
      true
    }) do
      PeriodicCatalogRefresher.start!(interval: 0.01)
      Timeout.timeout(10) { started.pop }
      # We are now inside refresh!, which a kill would abort.
      PeriodicCatalogRefresher.stop!
    end

    assert finished.true?, "stop! must not abort a refresh that is already running"
    assert_not PeriodicCatalogRefresher.running?
  end

  test "stop! terminates the background thread" do
    AirCatalogService.stub(:refresh!, -> { true }) do
      PeriodicCatalogRefresher.start!(interval: 60)
    end
    assert PeriodicCatalogRefresher.running?

    PeriodicCatalogRefresher.stop!
    refute PeriodicCatalogRefresher.running?
  end

  test "the started thread refreshes on its interval" do
    refreshed = Queue.new
    # Small interval so the loop ticks promptly; the Queue makes the assertion
    # deterministic (we block until the first refresh actually happens) rather
    # than relying on a fixed sleep.
    AirCatalogService.stub(:refresh!, -> { refreshed << true; true }) do
      PeriodicCatalogRefresher.start!(interval: 0.01)
      Timeout.timeout(5) { refreshed.pop }
      assert true, "thread invoked refresh at least once"
    ensure
      PeriodicCatalogRefresher.stop!
    end
  end
end
