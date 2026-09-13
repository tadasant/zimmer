# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The operator-facing half of QueuedJobMaintenance: the `/health` panel that keeps
# a human inside Zimmer during a queue incident instead of sending them to
# GoodJob's own dashboard (#335).
class HealthControllerQueuedJobsTest < ActionDispatch::IntegrationTest
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    GoodJob::Job.delete_all
    AppSetting.delete_all
    GoodJob::Setting.delete_all

    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ApplicationController.recovery_mode_reconciled_at = nil
  end

  teardown do
    GoodJob::Job.delete_all
    GoodJob::Setting.delete_all
    Rails.cache.clear
    Rails.cache = @original_cache
    ApplicationController.recovery_mode_reconciled_at = nil
  end

  def enqueue_good_job(job_class: "CanaryJob", queue_name: "pollers", **attrs)
    id = SecureRandom.uuid

    GoodJob::Job.create!(
      id: id, active_job_id: id, job_class: job_class, queue_name: queue_name,
      priority: 0, scheduled_at: Time.current,
      serialized_params: {
        "job_class" => job_class, "job_id" => id, "queue_name" => queue_name,
        "priority" => 0, "arguments" => [], "executions" => 0, "locale" => "en"
      },
      **attrs
    )
  end

  # === The panel ===

  test "the dashboard renders a row per class and queue, with the count on the control" do
    2.times { enqueue_good_job }
    enqueue_good_job(job_class: "HeartbeatSweepJob", queue_name: "default")

    get health_dashboard_path

    assert_response :success
    assert_select "h3", text: "Queued Job Maintenance"
    assert_select "input[name=job_class][value=CanaryJob]"
    assert_select "input[name=expected_count][value='2']"
    assert_select "input[name=job_class][value=HeartbeatSweepJob]"
  end

  test "the panel never offers a control for an agents-queue row" do
    enqueue_good_job(job_class: "AgentSessionJob", queue_name: "agents")

    get health_dashboard_path

    assert_response :success
    assert_select "input[name=job_class][value=AgentSessionJob]", false
    assert_match(/Nothing is waiting/, response.body)
  end

  # `eligible` scopes by equality, so there is no predicate for "job_class IS
  # NULL". A control on such a row would post a half-scope matching more rows than
  # the line it sits beside, and the count confirmation would refuse it every
  # time — a permanently dead button. Show the count, withhold the controls.
  test "a row missing a class or a queue is rendered without controls" do
    enqueue_good_job.update_columns(job_class: nil)

    get health_dashboard_path

    assert_response :success
    assert_match(/No controls: this row is missing a class or a queue name/, response.body)
    assert_select "form[action=?]", discard_queued_jobs_health_path, false
    assert_select "form[action=?]", reschedule_queued_jobs_health_path, false
  end

  # === The actions ===

  test "discarding from the panel discards and names the classes in the flash" do
    2.times { enqueue_good_job }

    post discard_queued_jobs_health_path,
      params: { queue_name: "pollers", expected_count: 2 }

    assert_redirected_to health_dashboard_path
    assert_match(/Discarded 2 queued jobs \(CanaryJob 2\)/, flash[:notice])
    assert_match(/Not recoverable/, flash[:notice])
    assert_equal 2, GoodJob::Job.where.not(finished_at: nil).count
  end

  test "a stale count from a page rendered before the queue moved is refused, not acted on" do
    3.times { enqueue_good_job }

    post discard_queued_jobs_health_path,
      params: { queue_name: "pollers", expected_count: 2 }

    assert_redirected_to health_dashboard_path
    assert_match(/Count confirmation failed/, flash[:alert])
    assert_match(/expected_count=3/, flash[:alert])
    assert_equal 0, GoodJob::Job.where.not(finished_at: nil).count
  end

  test "the agents queue is refused from the UI as well" do
    post discard_queued_jobs_health_path,
      params: { queue_name: "agents", expected_count: 0 }

    assert_redirected_to health_dashboard_path
    assert_match(/protected/, flash[:alert])
  end

  test "rescheduling from the panel moves the work and says where to" do
    job = enqueue_good_job(scheduled_at: 1.hour.ago)

    post reschedule_queued_jobs_health_path,
      params: { queue_name: "pollers", expected_count: 1, delay_minutes: 15 }

    assert_redirected_to health_dashboard_path
    assert_match(/Rescheduled 1 queued job \(CanaryJob 1\)/, flash[:notice])
    assert_nil job.reload.finished_at
    assert_in_delta 15.minutes.from_now.to_i, job.scheduled_at.to_i, 5
  end

  # The panel is one card on a page whose whole job is to be readable when the
  # instance is unwell. A `good_jobs` read that fails must cost the panel, not the
  # dashboard.
  test "a failing breakdown read degrades the panel instead of the page" do
    QueuedJobMaintenance.stubs(:breakdown).raises(ActiveRecord::StatementInvalid, "nope")

    get health_dashboard_path

    assert_response :success
    assert_match(/Nothing is waiting/, response.body)
  end
end
