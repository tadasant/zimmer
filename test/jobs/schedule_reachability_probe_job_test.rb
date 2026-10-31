# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class ScheduleReachabilityProbeJobTest < ActiveJob::TestCase
  setup do
    @condition = trigger_conditions(:enabled_schedule_condition)
  end

  test "runs on the pollers queue" do
    assert_equal "pollers", ScheduleReachabilityProbeJob.new.queue_name
  end

  test "observes every gated condition on an enabled trigger, due or not" do
    @condition.update!(configuration: @condition.configuration.merge("require_reachable" => [ "zimmer" ]),
                       last_triggered_at: Time.current)
    ScheduleReachabilityGate.stubs(:probe).returns({ "reachable" => true, "reason" => nil })

    ScheduleReachabilityProbeJob.perform_now

    assert @condition.reload.schedule_reachability_state["reachable_since"].present?
  end

  test "leaves ungated and disabled conditions alone" do
    ScheduleReachabilityGate.expects(:observe!).never
    ScheduleReachabilityProbeJob.perform_now

    @condition.update!(configuration: @condition.configuration.merge("require_reachable" => [ "zimmer" ]))
    @condition.trigger.update_column(:status, "disabled")
    ScheduleReachabilityProbeJob.perform_now
  end

  test "one condition raising does not stop the pass" do
    @condition.update!(configuration: @condition.configuration.merge("require_reachable" => [ "zimmer" ]))
    ScheduleReachabilityGate.stubs(:observe!).raises(StandardError, "boom")
    ErrorReporter.expects(:report_exception).once

    assert_nothing_raised { ScheduleReachabilityProbeJob.perform_now }
  end
end
