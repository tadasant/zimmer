# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Guards the guard: a test that swaps Rails.cache and does not put it back must
# FAIL, and must not take the rest of its worker down with it.
#
# The regression this exists for is #1119 meeting #1121 — a `setup` that raised
# on a deleted constant before capturing the original store, a `teardown` that
# restored nil anyway, and a run of NoMethodError-on-nil errors in files that
# never touched the cache. The point of the guard is that the same mistake now costs one failing
# file with the leak named in the message. See test/support/cache_isolation_guard.rb.
class CacheIsolationGuardTest < ActiveSupport::TestCase
  test "the boot store was captured, otherwise every check below is vacuous" do
    assert_not_nil CacheIsolationGuard.boot_store
    assert CacheIsolationGuard.intact?, "a test must start on the boot store"
  end

  test "restore! reports what it found and puts the boot store back" do
    leaked = ActiveSupport::Cache::MemoryStore.new
    Rails.cache = leaked

    assert_not CacheIsolationGuard.intact?
    assert_same leaked, CacheIsolationGuard.restore!
    assert CacheIsolationGuard.intact?
  end

  # The wiring, not just the helper: a leaking test run through the real callback
  # chain fails, and the store is back for whatever runs next. Run in-process on a
  # throwaway subclass, which is the only way to observe a failure without failing.
  test "a test that leaks Rails.cache fails, and the leak stops there" do
    leaked = ActiveSupport::Cache::MemoryStore.new
    result = run_probe { Rails.cache = leaked }

    assert_equal 1, result.failures.size, "the leak must fail the test that caused it"
    assert_includes result.failures.first.message, "Rails.cache was left as"
    assert_includes result.failures.first.message, "CacheIsolationGuardProbe#test_probe"
    assert CacheIsolationGuard.intact?,
      "the guard restores the boot store, so the next test in this worker is unaffected"
  end

  test "a test that restores Rails.cache itself is left alone" do
    result = run_probe do
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      Rails.cache = original
      assert CacheIsolationGuard.intact?
    end

    assert_empty result.failures, "the ~20 files that swap and restore must stay green"
  end

  # The incident, reproduced: a setup that raises before it captures the store,
  # and a teardown that restores whatever it captured — nil.
  test "a setup that raises before capturing the store fails only its own test" do
    result = run_probe_class do
      setup { raise NameError, "uninitialized constant AlertService" }
      setup do
        @original_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
      end
      teardown { Rails.cache = @original_cache }
      define_method(:test_probe) { flunk "a test whose setup raised never runs its body" }
    end

    messages = result.failures.map(&:message)
    assert messages.any? { |m| m.include?("uninitialized constant AlertService") }, "the real cause is still reported"
    leak = messages.find { |m| m.include?("Rails.cache was left as nil") }
    assert leak, "the nil restore is caught, not passed on to the next test"
    assert_includes leak, "CacheIsolationGuardProbe#test_probe"
    assert CacheIsolationGuard.intact?
  end

  # The far edge: a leak the teardown check never saw is caught by the next test's
  # setup. That test is told it is the messenger, and it still runs — its own
  # setup has to get the chance to capture a real store.
  test "a leak that reaches the next setup is caught there, and that test still runs" do
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    body_ran = false
    result = run_probe do
      body_ran = true
      assert CacheIsolationGuard.intact?, "the body runs on the boot store"
    end

    assert body_ran, "recording the failure rather than raising lets the test's own setup and body run"
    assert_equal 1, result.failures.size
    assert_includes result.failures.first.message, "an earlier test in this worker"
    assert CacheIsolationGuard.intact?
  end

  # BroadcastServiceTest's shape. Mocha removes a stub on the reader after
  # ActiveSupport's teardown callbacks, so a guard that called Rails.cache would
  # still see the stub there and flag a test that leaks nothing.
  test "a mocha stub on Rails.cache is not a leak" do
    result = run_probe do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      assert_kind_of ActiveSupport::Cache::MemoryStore, Rails.cache
    end

    assert_empty result.failures, "mocha restores its own stub; the guard must not claim it leaked"
    assert CacheIsolationGuard.intact?
  end

  private

  # Runs `body` as a single test through the whole ActiveSupport::TestCase
  # callback chain and hands back its Minitest result.
  #
  # The subclass is removed from Minitest's runnable list immediately: a class
  # created mid-run is otherwise a real test case that the suite may try to run
  # again on its own, and this one fails on purpose.
  def run_probe(&body)
    run_probe_class { define_method(:test_probe, &body) }
  end

  # The same, with a class body of its own — for a probe that needs setup and
  # teardown callbacks, not just a test method named `test_probe`.
  def run_probe_class(&class_body)
    probe = Class.new(ActiveSupport::TestCase) do
      def self.name = "CacheIsolationGuardProbe"
    end
    probe.class_eval(&class_body)
    Minitest::Runnable.runnables.delete(probe)

    probe.new(:test_probe).run
  end
end
