# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The operator-facing half of QueueRecoveryMode: the health dashboard controls
# and the global banner that makes a halted instance impossible to mistake for a
# healthy one.
class HealthControllerQueueRecoveryModeTest < ActionDispatch::IntegrationTest
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    AlertService.stubs(:raise_alert).returns(true)

    AppSetting.delete_all
    GoodJob::Setting.delete_all

    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    # The web backstop throttles itself with a process-local monotonic clock, which
    # no amount of travel_to moves. Clear it so each test gets the first request.
    ApplicationController.recovery_mode_reconciled_at = nil
  end

  teardown do
    Rails.cache.clear
    Rails.cache = @original_cache
    GoodJob::Setting.delete_all
    ApplicationController.recovery_mode_reconciled_at = nil
  end

  test "the backstop check is throttled to one per process interval" do
    QueueRecoveryMode.expects(:expire_if_due!).once.returns(false)

    get root_path
    get root_path
  end

  test "entering from the dashboard halts the demand-side queues and not agents" do
    post enter_queue_recovery_mode_health_path, params: { reason: "trigger stampede", ttl_minutes: 30 }

    assert_redirected_to health_dashboard_path
    assert QueueRecoveryMode.active?
    assert_equal QueueRecoveryMode::HALTED_QUEUES.sort, GoodJob.paused(:queues).sort
    refute_includes GoodJob.paused(:queues), "agents"
  end

  test "an out-of-range ttl is clamped rather than rejected" do
    freeze_time do
      post enter_queue_recovery_mode_health_path, params: { ttl_minutes: 9999 }

      assert_equal Time.current + QueueRecoveryMode::MAX_TTL, QueueRecoveryMode.status.expires_at
    end
  end

  test "exiting resumes processing and is idempotent" do
    post enter_queue_recovery_mode_health_path, params: { reason: "x" }

    post exit_queue_recovery_mode_health_path
    assert_redirected_to health_dashboard_path
    refute QueueRecoveryMode.active?
    assert_empty GoodJob.paused(:queues)

    post exit_queue_recovery_mode_health_path
    assert_redirected_to health_dashboard_path
    refute QueueRecoveryMode.active?
  end

  # The escape hatch must not be behind the cooldown that the other maintenance
  # actions share — least of all the way back out of it, which has to work on the
  # first try during an incident.
  test "the queue recovery controls are not rate limited by the health cooldown" do
    post cleanup_processes_health_path

    post enter_queue_recovery_mode_health_path, params: { reason: "x" }
    assert QueueRecoveryMode.active?

    post exit_queue_recovery_mode_health_path
    refute QueueRecoveryMode.active?
  end

  test "the dashboard offers the control when off and the state when on" do
    get health_dashboard_path
    assert_response :success
    assert_select "form[action=?]", enter_queue_recovery_mode_health_path

    QueueRecoveryMode.enter!(reason: "916 jobs/hour", actor: "test")

    get health_dashboard_path
    assert_response :success
    assert_select "form[action=?]", exit_queue_recovery_mode_health_path
    assert_match "916 jobs/hour", response.body
  end

  test "the global banner appears on ordinary pages while halted, and only then" do
    get health_dashboard_path
    assert_response :success
    assert_no_match(/Queue recovery mode\./, response.body)

    QueueRecoveryMode.enter!(reason: "trigger stampede", actor: "test")

    get root_path
    assert_response :success
    assert_match(/Queue recovery mode\./, response.body)
    assert_match "trigger stampede", response.body
  end

  test "a request reconciles an expired window even with no worker running" do
    travel_to Time.utc(2026, 8, 3, 12, 0, 0) do
      QueueRecoveryMode.enter!(ttl: 10.minutes, actor: "test")
    end

    travel_to Time.utc(2026, 8, 3, 12, 11, 0) do
      get root_path

      assert_response :success
      assert_empty GoodJob.paused(:queues),
        "the web process is the backstop for a saturated agents queue"
    end
  end

  test "entering refuses, rather than lying, when GoodJob pauses are disabled" do
    QueueRecoveryMode.stubs(:enabled?).returns(false)

    post enter_queue_recovery_mode_health_path, params: { reason: "x" }

    assert_redirected_to health_dashboard_path
    assert_match(/enable_pauses/, flash[:alert])
    refute QueueRecoveryMode.active?
  end
end
