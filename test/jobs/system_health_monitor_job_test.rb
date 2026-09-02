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

  # HealthMonitorService reports :critical once the count of *ready* GoodJob rows
  # reaches QUEUE_DEPTH_CRITICAL_THRESHOLD (100) AND the head of the queue has been
  # waiting QUEUE_STALL_CRITICAL_AGE. Drive that with real rows so the job exercises
  # the real health computation rather than a stub.

  # Ready work: due now and unclaimed. `waiting_for` backdates it — a queue whose
  # oldest job arrived a moment ago is draining, not stalled, and is deliberately not
  # critical.
  #
  # `scheduled_at` is set to match `created_at` because that is the shape GoodJob
  # actually writes: `GoodJob::Job.enqueue_args` always populates `scheduled_at`,
  # defaulting it to the creation time, even for an immediate enqueue.
  def enqueue_ready_jobs(count, waiting_for: HealthMonitorService::QUEUE_STALL_CRITICAL_AGE + 1.minute)
    enqueued_at = waiting_for.ago
    insert_jobs(count) { { created_at: enqueued_at, updated_at: enqueued_at, scheduled_at: enqueued_at } }
  end

  # Future-dated work: wake-up triggers, scheduled polls, retry backoffs. Waiting on
  # the clock, not on a worker.
  def enqueue_scheduled_jobs(count, due_in: 1.hour)
    insert_jobs(count) { { scheduled_at: due_in.from_now } }
  end

  # Rows a worker has already picked up. GoodJob marks these with locked_by_id; they
  # are being worked, not waiting.
  def claim_jobs(count)
    insert_jobs(count) { { locked_by_id: SecureRandom.uuid, locked_at: Time.current } }
  end

  def insert_jobs(count)
    now = Time.current
    rows = Array.new(count) do
      { queue_name: "default", job_class: "PlaceholderJob", created_at: now, updated_at: now }.merge(yield)
    end
    GoodJob::Job.insert_all(rows) if rows.any?
  end

  def make_queue_critical
    enqueue_ready_jobs(HealthMonitorService::QUEUE_DEPTH_CRITICAL_THRESHOLD + 5)
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
        opts[:details].to_s.include?("Ready (waiting on a worker):")
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

  # The alert body must separate the number that means "work is waiting" from the two
  # populations that are not backlog. Reading them as one number is what made this
  # alert page four times in three days with no real backlog behind it.
  test "the alert body separates ready work from claimed and scheduled jobs" do
    make_queue_critical
    enqueue_scheduled_jobs(20)
    claim_jobs(7)

    SystemHealthMonitorJob.perform_now # streak -> 1

    details = ""
    AlertService.expects(:raise_alert).once.with do |_title, opts|
      details = opts[:details].to_s
      true
    end
    SystemHealthMonitorJob.perform_now

    assert_includes details, "Ready (waiting on a worker): 105"
    assert_includes details, "7 claimed (executing now)"
    assert_includes details, "20 scheduled (future-dated)"
  end

  # The number alone is not triageable. `agents` holds a thread for the whole life
  # of a session while `default` and `pollers` turn jobs over in milliseconds, so
  # the same ready count means "one starved queue" or "everything is busy" — and
  # those want opposite responses. Naming the queue and the job classes in the page
  # is what makes the next firing readable by a responder with no route to /jobs.
  test "the alert body names the backlogged queues and job classes" do
    make_queue_critical
    insert_jobs(40) do
      { queue_name: "agents", job_class: "AgentSessionJob",
        created_at: 20.minutes.ago, updated_at: 20.minutes.ago, scheduled_at: 20.minutes.ago }
    end

    SystemHealthMonitorJob.perform_now # streak -> 1

    details = ""
    AlertService.expects(:raise_alert).once.with do |_title, opts|
      details = opts[:details].to_s
      true
    end
    SystemHealthMonitorJob.perform_now

    assert_includes details, "Ready by queue: default 105, agents 40"
    assert_includes details, "Ready by job class: PlaceholderJob 105, AgentSessionJob 40"
  end

  # The head-of-line age is the number this page and the Grafana `not draining`
  # rule both fire on, and across every queue at once it cannot tell a starved lane
  # from a wedged worker. `make_queue_critical` fills `default` with rows waiting
  # QUEUE_STALL_CRITICAL_AGE + 1m; the `agents` rows below are older, so they own
  # the head of line and the page must say so.
  test "the alert body names the lane behind the head-of-line age, and each lane's own" do
    make_queue_critical
    insert_jobs(40) do
      { queue_name: "agents", job_class: "AgentSessionJob",
        created_at: 40.minutes.ago, updated_at: 40.minutes.ago, scheduled_at: 40.minutes.ago }
    end

    SystemHealthMonitorJob.perform_now # streak -> 1

    details = ""
    AlertService.expects(:raise_alert).once.with do |_title, opts|
      details = opts[:details].to_s
      true
    end
    SystemHealthMonitorJob.perform_now

    assert_includes details, "(agents / AgentSessionJob)",
                    "the first bullet must answer 'old where', not only 'old'"
    assert_match(/Oldest ready by queue: agents 40m, default 11m/, details)
  end

  # The breakdown is three extra scans of `good_jobs` at exactly the moment
  # the database may be the thing going wrong. A depth number that reaches a human
  # beats a richer one that raises on the way, so the detail degrades and the page
  # still goes out.
  test "a breakdown that cannot be read does not stop the page going out" do
    make_queue_critical
    HealthMonitorService.any_instance.stubs(:ready_backlog_breakdown)
                        .raises(ActiveRecord::StatementInvalid, "canceling statement due to statement timeout")

    SystemHealthMonitorJob.perform_now # streak -> 1

    details = ""
    AlertService.expects(:raise_alert).once.with do |_title, opts|
      details = opts[:details].to_s
      true
    end
    SystemHealthMonitorJob.perform_now

    assert_includes details, "Ready (waiting on a worker): 105"
    assert_includes details, "Ready by queue: unavailable"
    assert_includes details, "Ready by job class: unavailable"
    assert_includes details, "Oldest ready by queue: unavailable"
    refute_includes details, "( / )",
                    "with no breakdown to read, the first bullet keeps the age and drops the lane"
  end

  test "does not alert on a deep queue that is still draining" do
    # Depth well past the critical threshold, but the oldest job arrived seconds ago:
    # a busy queue, not a stalled one.
    enqueue_ready_jobs(HealthMonitorService::QUEUE_DEPTH_CRITICAL_THRESHOLD + 50, waiting_for: 5.seconds)

    AlertService.expects(:raise_alert).never
    SystemHealthMonitorJob.perform_now
    SystemHealthMonitorJob.perform_now

    assert_nil Rails.cache.read(SystemHealthMonitorJob::STREAK_CACHE_KEY)
  end

  # The 2026-08-16 03:28Z firing, exactly: 106 unfinished rows, of which only 68 were
  # ready. Under the old total-pending rule this paged. It must not now.
  test "does not alert on the 2026-08-16 firing's numbers (106 pending, 68 ready)" do
    enqueue_ready_jobs(68)
    enqueue_scheduled_jobs(23)
    claim_jobs(15)

    assert_equal 106, GoodJob::Job.where(finished_at: nil).count

    AlertService.expects(:raise_alert).never
    SystemHealthMonitorJob.perform_now
    SystemHealthMonitorJob.perform_now
  end

  # The other half of the same guarantee: a genuine stalled backlog still pages.
  test "still alerts on a genuine stalled backlog of 200 ready jobs" do
    enqueue_ready_jobs(200, waiting_for: 30.minutes)

    SystemHealthMonitorJob.perform_now # streak -> 1

    AlertService.expects(:raise_alert).once
    SystemHealthMonitorJob.perform_now
  end
end
