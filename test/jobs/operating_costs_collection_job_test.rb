# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class OperatingCostsCollectionJobTest < ActiveJob::TestCase
  include OperatingCostFixtures

  test "derives, rebuilds and records a run, and a second run writes nothing new" do
    seed_operating_costs!
    LiveUsageEvent.record!(engine: "openai_realtime", operation: "voice_session", vendor: "openai", model: "gpt-realtime", seconds: 60,
                           occurred_at: 1.day.ago)

    run = OperatingCostsCollectionJob.perform_now

    assert_equal "succeeded", run.status
    assert OperatingCostObservation.exists?(source: "derived")
    entries = OperatingCostDailyEntry.order(:account_id, :date).pluck(:account_id, :date, :amount_usd)

    OperatingCostsCollectionJob.perform_now

    assert_equal entries, OperatingCostDailyEntry.order(:account_id, :date).pluck(:account_id, :date, :amount_usd)
    assert_equal 2, OperatingCostCollectionRun.where(collector: "derived", status: "succeeded").count
  end

  test "a failure is recorded on the run rather than raised" do
    OperatingCosts::DerivedCollector.any_instance.stubs(:observations).raises(RuntimeError, "boom")

    run = OperatingCostsCollectionJob.perform_now

    assert_equal "failed", run.status
    assert_match "boom", run.error
  end
end
