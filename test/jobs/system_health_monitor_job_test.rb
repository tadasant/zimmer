# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class SystemHealthMonitorJobTest < ActiveJob::TestCase
  # The production cache is null_store in test, which would make every streak read
  # return nil and defeat the hysteresis logic. Swap in a real in-memory store so
  # the consecutive-critical streak actually persists across perform calls, then
  # restore the original store afterwards.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.delete(SystemHealthMonitorJob::STREAK_CACHE_KEY)
  end

  teardown do
    Rails.cache = @original_cache
    Mocha::Mockery.instance.teardown
  end

  # HealthMonitorService reports :critical once the count of unfinished GoodJob
  # rows reaches QUEUE_DEPTH_CRITICAL_THRESHOLD (100). Drive that with real rows so
  # the job exercises the real health computation rather than a stub.
  def enqueue_unfinished_jobs(count)
    now = Time.current
    rows = Array.new(count) do
      { queue_name: "default", job_class: "PlaceholderJob", created_at: now, updated_at: now }
    end
    GoodJob::Job.insert_all(rows) if rows.any?
  end

  def make_queue_critical
    enqueue_unfinished_jobs(HealthMonitorService::QUEUE_DEPTH_CRITICAL_THRESHOLD + 5)
  end

  test "runs on the dedicated pollers queue (not default)" do
    assert_equal "pollers", SystemHealthMonitorJob.new.queue_name
  end

  test "is a singleton (total_limit 1) so overlapping checks cannot stack" do
    config = SystemHealthMonitorJob.good_job_concurrency_config
    assert_equal 1, config[:total_limit]
    assert_equal "system_health_monitor", SystemHealthMonitorJob.new.good_job_concurrency_key
  end

  test "does not alert when the queue is healthy" do
    AlertService.expects(:raise_alert).never
    SystemHealthMonitorJob.perform_now
  end

  test "does not alert on the first critical check (hysteresis: needs a confirming check)" do
    make_queue_critical

    AlertService.expects(:raise_alert).never
    SystemHealthMonitorJob.perform_now

    assert_equal 1, Rails.cache.read(SystemHealthMonitorJob::STREAK_CACHE_KEY)
  end

  test "alerts once the backlog is critical for two consecutive checks" do
    make_queue_critical

    # First check builds the streak but stays quiet.
    AlertService.expects(:raise_alert).never
    SystemHealthMonitorJob.perform_now

    # Second consecutive critical check pages, with the stable source + dedup key.
    AlertService.expects(:raise_alert).once.with do |title, opts|
      title == "Queue backlog critical" &&
        opts[:source] == "SystemHealthMonitorJob" &&
        opts[:dedup_key] == SystemHealthMonitorJob::ALERT_DEDUP_KEY &&
        opts[:details].to_s.include?("Pending:")
    end
    SystemHealthMonitorJob.perform_now
  end

  test "a healthy check between criticals resets the streak (no premature alert)" do
    make_queue_critical

    AlertService.expects(:raise_alert).never
    SystemHealthMonitorJob.perform_now # streak -> 1

    # Drain the backlog: the next check is healthy and must reset the streak.
    GoodJob::Job.where(finished_at: nil).delete_all
    SystemHealthMonitorJob.perform_now # healthy -> streak cleared
    assert_nil Rails.cache.read(SystemHealthMonitorJob::STREAK_CACHE_KEY)

    # Backlog returns: a single critical check must NOT immediately alert — the
    # streak has to rebuild from scratch.
    make_queue_critical
    AlertService.expects(:raise_alert).never
    SystemHealthMonitorJob.perform_now # streak -> 1 again, still quiet
    assert_equal 1, Rails.cache.read(SystemHealthMonitorJob::STREAK_CACHE_KEY)
  end
end
