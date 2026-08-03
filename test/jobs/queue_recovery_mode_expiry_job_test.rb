# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class QueueRecoveryModeExpiryJobTest < ActiveSupport::TestCase
  setup do
    AppSetting.delete_all
    GoodJob::Setting.delete_all
    AlertService.stubs(:raise_alert).returns(true)
  end

  teardown do
    GoodJob::Setting.delete_all
  end

  # The whole point of the queue choice. A watchdog on `pollers`, `triggers` or
  # `default` would be paused by the state it exists to clear.
  test "runs on the one queue recovery mode does not halt" do
    assert_equal "agents", QueueRecoveryModeExpiryJob.new.queue_name
    refute_includes QueueRecoveryMode::HALTED_QUEUES, QueueRecoveryModeExpiryJob.new.queue_name
  end

  test "lifts a halt whose window has elapsed" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) { QueueRecoveryMode.enter!(ttl: 10.minutes) }

    travel_to Time.utc(2026, 8, 3, 12, 11, 0) do
      QueueRecoveryModeExpiryJob.perform_now

      assert_empty GoodJob.paused(:queues)
    end
  end

  test "leaves a live window alone" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) { QueueRecoveryMode.enter!(ttl: 60.minutes) }

    travel_to Time.utc(2026, 8, 3, 12, 5, 0) do
      QueueRecoveryModeExpiryJob.perform_now

      assert QueueRecoveryMode.active?
      assert_equal QueueRecoveryMode::HALTED_QUEUES.sort, GoodJob.paused(:queues).sort
    end
  end

  test "is a cheap no-op when the mode is off" do
    assert_nothing_raised { QueueRecoveryModeExpiryJob.perform_now }
    refute QueueRecoveryMode.active?
  end
end
