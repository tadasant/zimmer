# frozen_string_literal: true

require "test_helper"

# One recovery edge, one announcement — under real concurrency (#606).
#
# The observed failure was two fleet-maintenance sessions created in the same
# second from one `quota_available` edge, each running the wake policy against the
# same waiting queue and each applying its own caps, so the effective ceiling for
# that recovery was doubled. Upstream of the trigger, this is where it starts: the
# level that records whether a recovery has been ANNOUNCED was READ, then acted
# on, with the whole gate evaluation in between — so two passes could hold the
# same unspent edge at once.
#
# Non-transactional deliberately. The race is between two database connections,
# and a transactional test would hide one thread's writes behind the other's
# snapshot — the test would pass against the broken code.
class QuotaAvailabilityMonitorConcurrencyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  setup do
    @app_setting_existed = AppSetting.exists?
    AppSetting.editable.update!(quota_pool_available: false, quota_pool_available_changed_at: 1.hour.ago)
  end

  teardown do
    if @app_setting_existed
      AppSetting.editable.update!(quota_pool_available: nil, quota_pool_available_changed_at: nil)
    else
      AppSetting.delete_all
    end
  end

  # Both passes read the level, both pass the gate, and only then does either one
  # touch the column. Without the claim they both fire; with it, exactly one does.
  test "two passes observing the same rising edge fire the event once" do
    results = race_two_passes { QuotaAvailabilityMonitor.check! }

    assert_equal [ false, true ], results.sort_by { |fired| fired ? 1 : 0 },
      "exactly one pass may announce a recovery, and exactly one must"
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == SystemEventTriggerJob },
      "one edge must enqueue one SystemEventTriggerJob"
    assert_equal true, AppSetting.editable.reload.quota_pool_available
  end

  # `request_wake!` fires the same event, to be answered by the same fleet
  # session, from the same column — so it has to lose the same race.
  test "a request_wake! racing a check! on one recovery fires the event once" do
    results = race_two_passes(
      -> { QuotaAvailabilityMonitor.check! },
      -> { QuotaAvailabilityMonitor.request_wake!(reason: "parked spot session") }
    )

    assert_equal [ false, true ], results.sort_by { |fired| fired ? 1 : 0 },
      "a check! and a request_wake! holding one recovery must not both spend it"
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == SystemEventTriggerJob }
  end

  # Over-tightening is the failure mode on the other side: a claim that outlived
  # its recovery would leave the parked sessions asleep through the NEXT outage.
  # The predicate is the unspent level and nothing else, so re-exhausting and
  # recovering again fires again.
  test "a pool that re-exhausts and recovers again is a second edge, and fires again" do
    with_available_pool do
      assert QuotaAvailabilityMonitor.check!, "the first recovery fires"

      QuotaAvailabilityMonitor.record_unavailable!
      assert QuotaAvailabilityMonitor.check!, "a genuine second recovery fires too"
    end

    assert_equal 2, enqueued_jobs.count { |job| job[:job] == SystemEventTriggerJob }
  end

  private

  # Run two passes on two threads, released into the claim at the same instant.
  # The barrier sits in #spot_gate_hold, the last thing either pass does before it
  # acts on the level it read — so both threads are holding the same
  # `previous == false` when they race.
  def race_two_passes(*passes, &block)
    passes = [ block, block ] if passes.empty?
    barrier = Concurrent::CyclicBarrier.new(2)

    with_available_pool(gate_barrier: barrier) do
      passes
        .map { |pass| Thread.new { ActiveRecord::Base.connection_pool.with_connection { pass.call } } }
        .map { |thread| thread.join(20) && thread.value }
    end
  end

  # Stub the two reads `check!` makes of the world outside the settings row, so
  # the test is about the level and not about account fixtures or the spot gate.
  # `define_singleton_method` rather than a mocha stub because these are called
  # from threads.
  def with_available_pool(gate_barrier: nil)
    original_pool = QuotaAvailabilityMonitor.method(:pool_available?)
    original_gate = QuotaAvailabilityMonitor.method(:spot_gate_hold)

    QuotaAvailabilityMonitor.define_singleton_method(:pool_available?) { |_runtime| true }
    QuotaAvailabilityMonitor.define_singleton_method(:spot_gate_hold) do
      gate_barrier&.wait(10)
      nil
    end

    yield
  ensure
    QuotaAvailabilityMonitor.define_singleton_method(:pool_available?, original_pool)
    QuotaAvailabilityMonitor.define_singleton_method(:spot_gate_hold, original_gate)
  end
end
