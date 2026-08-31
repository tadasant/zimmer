# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
# The auth_health cases stub with `.stubs`. Without this the file only runs when
# some other file in the same process has already loaded mocha.
require "mocha/minitest"

class HealthMonitorServiceTest < ActiveSupport::TestCase
  setup do
    # Clear existing data from fixtures to ensure isolated tests
    # Delete dependent records first due to foreign key constraints
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    @mock_process_manager = MockProcessManager.new
    @service = HealthMonitorService.new(process_manager: @mock_process_manager)
  end

  # === Full Health Report Tests ===

  test "full_health_report returns all sections" do
    report = @service.full_health_report

    assert report.key?(:process_health)
    assert report.key?(:session_health)
    assert report.key?(:system_health)
    assert report.key?(:egress_health)
    assert report.key?(:sigterm_retry_health)
    assert report.key?(:api_error_retry_health)
    assert report.key?(:overall_status)
    assert report.key?(:generated_at)
  end

  test "egress_health reflects a degraded cache and drives overall status critical" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.write(EgressHealthCheck::CACHE_KEY, {
      "status" => "degraded",
      "detail" => "primary resolver 127.0.0.11 could not resolve api.anthropic.com",
      "resolver" => "127.0.0.11",
      "degraded_since" => Time.current.iso8601,
      "checked_at" => Time.current.iso8601
    })

    report = @service.full_health_report
    assert report[:egress_health][:status].critical?
    assert_equal "127.0.0.11", report[:egress_health][:resolver]
    assert report[:overall_status].critical?, "a degraded egress makes the system critical"
  ensure
    Rails.cache = original_cache
  end

  test "egress_health is healthy when no probe result is cached" do
    report = @service.full_health_report
    assert report[:egress_health][:status].healthy?
  end

  test "full_health_report generated_at is current time" do
    freeze_time = Time.current
    travel_to freeze_time do
      report = @service.full_health_report
      assert_in_delta freeze_time, report[:generated_at], 1.second
    end
  end

  # === Process Health Tests ===

  test "process_health returns correct structure" do
    health = @service.process_health

    assert health.key?(:active_count)
    assert health.key?(:active_processes)
    assert health.key?(:orphaned_count)
    assert health.key?(:orphaned_processes)
    assert health.key?(:tracked_count)
    assert health.key?(:status)
  end

  test "process_health tracks spawned processes" do
    @mock_process_manager.spawn_with_tracking([ "claude", "--test" ], correlation_id: "test-123")

    health = @service.process_health

    assert_equal 1, health[:tracked_count]
    assert_equal 1, health[:tracked_processes].size
  end

  test "process_health status is healthy when no orphaned processes" do
    health = @service.process_health

    assert health[:status].healthy?
    assert_equal :healthy, health[:status].status
  end

  # === Session Health Tests ===

  test "session_health returns correct structure" do
    health = @service.session_health

    assert health.key?(:sessions_by_status)
    assert health.key?(:total_sessions)
    assert health.key?(:recent_failures)
    assert health.key?(:failure_rate)
    assert health.key?(:error_categories)
    assert health.key?(:status)
  end

  test "session_health counts sessions by status" do
    # Create sessions with different statuses
    Session.create!(prompt: "Test 1", agent_runtime: "claude_code", status: :running, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    Session.create!(prompt: "Test 2", agent_runtime: "claude_code", status: :running, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    Session.create!(prompt: "Test 3", agent_runtime: "claude_code", status: :failed, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")

    health = @service.session_health

    assert_equal 2, health[:sessions_by_status]["running"]
    assert_equal 1, health[:sessions_by_status]["failed"]
  end

  test "session_health calculates failure rate" do
    # Create 10 sessions, 2 failed
    8.times do |i|
      Session.create!(prompt: "Test #{i}", agent_runtime: "claude_code", status: :needs_input, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end
    2.times do |i|
      Session.create!(prompt: "Failed #{i}", agent_runtime: "claude_code", status: :failed, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end

    health = @service.session_health

    assert_in_delta 0.2, health[:failure_rate], 0.01
  end

  test "session_health status is healthy with low failure rate" do
    8.times do |i|
      Session.create!(prompt: "Test #{i}", agent_runtime: "claude_code", status: :needs_input, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end

    health = @service.session_health

    assert health[:status].healthy?
  end

  test "session_health status is warning with elevated failure rate" do
    # Create 10 sessions, 2 failed (20% failure rate)
    8.times do |i|
      Session.create!(prompt: "Test #{i}", agent_runtime: "claude_code", status: :needs_input, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end
    2.times do |i|
      Session.create!(prompt: "Failed #{i}", agent_runtime: "claude_code", status: :failed, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end

    health = @service.session_health

    assert health[:status].warning?
  end

  test "session_health status is critical with high failure rate" do
    # Create 10 sessions, 4 failed (40% failure rate)
    6.times do |i|
      Session.create!(prompt: "Test #{i}", agent_runtime: "claude_code", status: :needs_input, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end
    4.times do |i|
      Session.create!(prompt: "Failed #{i}", agent_runtime: "claude_code", status: :failed, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end

    health = @service.session_health

    assert health[:status].critical?
  end

  test "session_health recent_failures only includes last 24 hours" do
    # Create old failure (more than 24 hours ago)
    old_session = Session.create!(
      prompt: "Old failure",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      title: "Old Failure Title"
    )
    old_session.update_column(:updated_at, 2.days.ago)

    # Create recent failure
    recent_session = Session.create!(
      prompt: "Recent failure",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      title: "Recent Failure Title"
    )

    health = @service.session_health

    assert_equal 1, health[:recent_failures].size
    assert_equal recent_session.id, health[:recent_failures].first[:id]
  end

  # === System Health Tests ===

  test "system_health returns correct structure" do
    health = @service.system_health

    assert health.key?(:queue_depth)
    assert health.key?(:queue_stats)
    assert health.key?(:worker_stats)
    assert health.key?(:recent_errors)
    assert health.key?(:database_status)
    assert health.key?(:status)
  end

  test "system_health database_status shows connected" do
    health = @service.system_health

    assert health[:database_status][:connected]
    assert health[:database_status].key?(:pool_size)
    assert health[:database_status].key?(:connections_in_use)
  end

  test "system_health status is healthy with low queue depth" do
    health = @service.system_health

    assert health[:status].healthy?
  end

  # === Queue Backlog Tests ===
  #
  # "Backlog" means work waiting on a worker: due now, unclaimed. The `good_jobs`
  # table also holds future-dated rows (wake-up triggers, scheduled polls, retry
  # backoffs) and rows a worker is executing right now — neither is waiting on
  # anything. Counting all three as one number paged four times in three days on the
  # Tadasant production deployment with no real backlog behind it.

  def insert_good_jobs(count)
    now = Time.current
    rows = Array.new(count) do
      { queue_name: "default", job_class: "PlaceholderJob", created_at: now, updated_at: now }.merge(yield)
    end
    GoodJob::Job.insert_all(rows) if rows.any?
  end

  # `scheduled_at` matches `created_at` because that is the shape GoodJob writes:
  # `GoodJob::Job.enqueue_args` always populates it, even for an immediate enqueue.
  def enqueue_ready_jobs(count, waiting_for: HealthMonitorService::QUEUE_STALL_CRITICAL_AGE + 1.minute)
    enqueued_at = waiting_for.ago
    insert_good_jobs(count) { { created_at: enqueued_at, updated_at: enqueued_at, scheduled_at: enqueued_at } }
  end

  def enqueue_scheduled_jobs(count, due_in: 1.hour)
    insert_good_jobs(count) { { scheduled_at: due_in.from_now } }
  end

  def claim_jobs(count)
    insert_good_jobs(count) { { locked_by_id: SecureRandom.uuid, locked_at: Time.current } }
  end

  # === Ready-backlog breakdown ===
  #
  # A ready count alone cannot tell a starved queue from a busy one, and Zimmer
  # runs five queues with very different thread counts and job durations. Every
  # triage of a backlog page opens with "deep with WHAT", and until this existed
  # the only answer was the GoodJob dashboard — which the agent sessions that
  # actually read these pages have no route to.

  test "ready_backlog_breakdown splits the backlog by queue and by job class" do
    insert_good_jobs(7) { { queue_name: "agents", job_class: "AgentSessionJob", scheduled_at: 5.minutes.ago } }
    insert_good_jobs(2) { { queue_name: "default", job_class: "SessionTitleJob", scheduled_at: 5.minutes.ago } }
    insert_good_jobs(1) { { queue_name: "pollers", job_class: "SlackTriggerPollerJob", scheduled_at: 5.minutes.ago } }

    breakdown = HealthMonitorService.new.ready_backlog_breakdown

    assert_equal({ "agents" => 7, "default" => 2, "pollers" => 1 }, breakdown[:by_queue])
    assert_equal({ "AgentSessionJob" => 7, "SessionTitleJob" => 2, "SlackTriggerPollerJob" => 1 },
                 breakdown[:by_job_class])
  end

  test "ready_backlog_breakdown orders biggest first so the starved queue reads first" do
    insert_good_jobs(2) { { queue_name: "default", scheduled_at: 5.minutes.ago } }
    insert_good_jobs(9) { { queue_name: "agents", scheduled_at: 5.minutes.ago } }

    assert_equal [ "agents", "default" ], HealthMonitorService.new.ready_backlog_breakdown[:by_queue].keys
  end

  # The breakdown must be taken over the same population as `ready_count`, or the
  # two halves of the alert would contradict each other — and a future-dated wake-up
  # counted as backlog is the exact arithmetic that paged four times in three days.
  test "ready_backlog_breakdown ignores scheduled and claimed work" do
    enqueue_ready_jobs(3)
    insert_good_jobs(5) { { queue_name: "agents", scheduled_at: 1.hour.from_now } }
    insert_good_jobs(4) { { queue_name: "agents", locked_by_id: SecureRandom.uuid, locked_at: Time.current } }

    breakdown = HealthMonitorService.new.ready_backlog_breakdown

    assert_equal({ "default" => 3 }, breakdown[:by_queue])
    assert_equal({ "PlaceholderJob" => 3 }, breakdown[:by_job_class])
    assert_equal 3, breakdown[:by_queue].values.sum,
                 "the breakdown must add up against ready_count, not against every unfinished row"
  end

  # The cap keeps the alert readable; the remainder keeps it honest. The alert
  # asks its reader to tell "concentrated in one queue" from "spread across every
  # queue", and five names with no total look identical whether they are the whole
  # backlog or a tenth of it.
  test "ready_backlog_breakdown caps the entries but reports what it cut" do
    %w[a b c d e f g].each_with_index do |queue, i|
      insert_good_jobs(10 - i) { { queue_name: queue, scheduled_at: 5.minutes.ago } }
    end

    breakdown = HealthMonitorService.new.ready_backlog_breakdown
    limit = HealthMonitorService::READY_BREAKDOWN_LIMIT

    assert_equal [ "a", "b", "c", "d", "e", "other (2 more)" ], breakdown[:by_queue].keys
    assert_equal limit + 1, breakdown[:by_queue].size
    assert_equal 5 + 4, breakdown[:by_queue]["other (2 more)"], "the remainder carries the counts it cut"
    assert_equal (4..10).sum, breakdown[:by_queue].values.sum,
                 "a capped breakdown must still add up against ready_count"
  end

  test "ready_backlog_breakdown adds no remainder when nothing was cut" do
    insert_good_jobs(3) { { queue_name: "agents", scheduled_at: 5.minutes.ago } }

    assert_equal({ "agents" => 3 }, HealthMonitorService.new.ready_backlog_breakdown[:by_queue])
  end

  # Ties would otherwise come out in whatever order the adapter felt like,
  # so two readings of an unchanged queue could disagree.
  test "ready_backlog_breakdown breaks ties by name so the order is stable" do
    %w[zebra alpha middle].each do |queue|
      insert_good_jobs(4) { { queue_name: queue, scheduled_at: 5.minutes.ago } }
    end

    assert_equal [ "alpha", "middle", "zebra" ],
                 HealthMonitorService.new.ready_backlog_breakdown[:by_queue].keys
  end

  # A row with no job_class is labelled rather than dropped, and blank and nil
  # are SUMMED onto one label rather than one silently replacing the other.
  test "ready_backlog_breakdown labels rows with no job class instead of losing them" do
    insert_good_jobs(2) { { job_class: nil, queue_name: "agents", scheduled_at: 5.minutes.ago } }
    insert_good_jobs(3) { { job_class: "", queue_name: "agents", scheduled_at: 5.minutes.ago } }

    breakdown = HealthMonitorService.new.ready_backlog_breakdown

    assert_equal({ HealthMonitorService::UNKNOWN_LABEL => 5 }, breakdown[:by_job_class])
    assert_equal breakdown[:by_queue].values.sum, breakdown[:by_job_class].values.sum
  end

  test "ready_backlog_breakdown is empty when nothing is waiting" do
    assert_equal({ by_queue: {}, by_job_class: {} }, HealthMonitorService.new.ready_backlog_breakdown)
  end

  # Three distinct answers, because they are three different facts about an
  # incident: the query failed, nothing is waiting, or here is the split.
  test "format_breakdown tells a failed read apart from an empty one" do
    assert_equal "unavailable", HealthMonitorService.format_breakdown(nil)
    assert_equal "none", HealthMonitorService.format_breakdown({})
    assert_equal "agents 231, default 18",
                 HealthMonitorService.format_breakdown({ "agents" => 231, "default" => 18 })
  end

  test "queue_depth counts ready work only, not scheduled or claimed jobs" do
    enqueue_ready_jobs(68)
    enqueue_scheduled_jobs(23)
    claim_jobs(15)

    health = @service.system_health
    stats = health[:queue_stats]

    assert_equal 106, stats[:pending_count], "every unfinished row is still reported"
    assert_equal 68, stats[:ready_count]
    assert_equal 23, stats[:scheduled_count]
    assert_equal 15, stats[:claimed_count]
    assert_equal 68, health[:queue_depth], "queue_depth is the ready backlog, not every unfinished row"
  end

  # The 2026-08-16 03:28Z production alert, exactly.
  test "the 2026-08-16 firing's numbers are not critical" do
    enqueue_ready_jobs(68)
    enqueue_scheduled_jobs(23)
    claim_jobs(15)

    status = @service.system_health[:status]

    refute status.critical?, "106 unfinished rows with only 68 ready is not a backlog collapse"
    assert status.warning?, "68 ready is still past the warning threshold and belongs on the dashboard"
  end

  test "a deep but draining queue is a warning, not critical" do
    enqueue_ready_jobs(HealthMonitorService::QUEUE_DEPTH_CRITICAL_THRESHOLD + 50, waiting_for: 5.seconds)

    status = @service.system_health[:status]

    refute status.critical?, "a deep queue whose head arrived seconds ago is busy, not stalled"
    assert status.warning?
  end

  test "a deep queue that has stopped draining is critical" do
    enqueue_ready_jobs(200, waiting_for: 30.minutes)

    status = @service.system_health[:status]

    assert status.critical?
    assert_includes status.message, "200 jobs ready"
    assert_includes status.message, "30m"
  end

  test "a queue of only future-dated jobs is healthy however deep it is" do
    enqueue_scheduled_jobs(500)

    health = @service.system_health

    assert_equal 0, health[:queue_depth]
    assert health[:status].healthy?, "work scheduled for later is waiting on the clock, not on a worker"
  end

  test "oldest_ready_age_seconds measures the head of the ready queue" do
    enqueue_ready_jobs(1, waiting_for: 15.minutes)
    enqueue_ready_jobs(1, waiting_for: 2.minutes)

    age = @service.system_health[:queue_stats][:oldest_ready_age_seconds]

    assert_in_delta 900, age, 5
  end

  test "oldest_ready_age_seconds ignores jobs that are not ready" do
    enqueue_scheduled_jobs(5)
    claim_jobs(5)

    stats = @service.system_health[:queue_stats]

    assert_nil stats[:oldest_ready_age_seconds], "nothing is waiting on a worker"
    assert @service.system_health[:status].healthy?
  end

  # A future-dated job that comes due starts waiting at its scheduled time, not at
  # the time it was created — otherwise a wake-up trigger enqueued yesterday would
  # look like a day-old stall the moment it becomes runnable.
  test "oldest_ready_age_seconds dates a due job from its scheduled time" do
    insert_good_jobs(1) { { created_at: 1.day.ago, updated_at: 1.day.ago, scheduled_at: 3.minutes.ago } }

    age = @service.system_health[:queue_stats][:oldest_ready_age_seconds]

    assert_in_delta 180, age, 5
  end

  # GoodJob always writes scheduled_at today, but the ready query has always tolerated
  # a NULL, so the age calculation has to agree with it rather than return nil.
  test "oldest_ready_age_seconds falls back to created_at when scheduled_at is null" do
    insert_good_jobs(1) { { created_at: 4.minutes.ago, updated_at: 4.minutes.ago } }

    stats = @service.system_health[:queue_stats]

    assert_equal 1, stats[:ready_count]
    assert_in_delta 240, stats[:oldest_ready_age_seconds], 5
  end

  # The alert body presents ready/claimed/scheduled as the whole of pending, so they
  # have to partition it — including for a locked row dated in the future, which would
  # otherwise be counted as both claimed and scheduled.
  test "ready, claimed and scheduled partition pending exactly" do
    enqueue_ready_jobs(4)
    enqueue_scheduled_jobs(3)
    claim_jobs(2)
    insert_good_jobs(1) { { locked_by_id: SecureRandom.uuid, locked_at: Time.current, scheduled_at: 1.hour.from_now } }

    stats = @service.system_health[:queue_stats]

    assert_equal 3, stats[:claimed_count], "the locked future-dated row is claimed, not scheduled"
    assert_equal 3, stats[:scheduled_count]
    assert_equal 4, stats[:ready_count]
    assert_equal stats[:pending_count],
      stats[:ready_count] + stats[:claimed_count] + stats[:scheduled_count]
  end

  test "format_wait renders seconds, minutes and hours" do
    assert_equal "45s", HealthMonitorService.format_wait(45)
    assert_equal "12m", HealthMonitorService.format_wait(12 * 60)
    assert_equal "2h 5m", HealthMonitorService.format_wait((2 * 3600) + (5 * 60))
    assert_equal "0s", HealthMonitorService.format_wait(nil)
  end

  # === Worker Statistics Tests ===
  #
  # A GoodJob capsule renews its process row every STALE_INTERVAL + jitter
  # (30-33s), so any active-worker threshold at or below that cadence reports
  # healthy workers as down. See triage session 1683.

  test "worker_statistics counts a worker that renewed within the last minute as active" do
    GoodJob::Process.delete_all
    create_good_job_process(seconds_since_heartbeat: 45)

    stats = @service.system_health[:worker_stats]

    assert_equal 1, stats[:total_workers]
    assert_equal 1, stats[:active_workers]
  end

  test "worker_statistics counts a worker at the top of the renew window as active" do
    GoodJob::Process.delete_all
    create_good_job_process(seconds_since_heartbeat: 33)

    stats = @service.system_health[:worker_stats]

    assert_equal 1, stats[:active_workers],
      "a worker at the top of GoodJob's 30-33s renew window is healthy, not down"
  end

  test "worker_statistics counts a worker GoodJob has not yet expired as active" do
    GoodJob::Process.delete_all
    create_good_job_process(seconds_since_heartbeat: GoodJob::Process::EXPIRED_INTERVAL.to_i - 10)

    stats = @service.system_health[:worker_stats]

    assert_equal 1, stats[:active_workers]
  end

  test "worker_statistics counts a worker past GoodJob's expiry as inactive" do
    GoodJob::Process.delete_all
    create_good_job_process(seconds_since_heartbeat: GoodJob::Process::EXPIRED_INTERVAL.to_i + 10)

    stats = @service.system_health[:worker_stats]

    assert_equal 1, stats[:total_workers]
    assert_equal 0, stats[:active_workers]
  end

  # The shape the incident alert actually printed: two registered workers, one of
  # them stale. active_workers must be a filtered count, not the row count.
  test "worker_statistics counts only the live worker when one of two has expired" do
    GoodJob::Process.delete_all
    create_good_job_process(seconds_since_heartbeat: 20, hostname: "live")
    create_good_job_process(seconds_since_heartbeat: GoodJob::Process::EXPIRED_INTERVAL.to_i + 60, hostname: "dead")

    stats = @service.system_health[:worker_stats]

    assert_equal 2, stats[:total_workers]
    assert_equal 1, stats[:active_workers]
  end

  test "worker_statistics active threshold clears GoodJob's renew cadence" do
    assert_operator HealthMonitorService::WORKER_ACTIVE_INTERVAL, :>,
      GoodJob::Process::STALE_INTERVAL * 1.1,
      "the threshold must exceed STALE_INTERVAL plus its maximum 10% jitter"
  end

  test "worker_statistics reports per-worker heartbeat age" do
    GoodJob::Process.delete_all
    create_good_job_process(seconds_since_heartbeat: 296, hostname: "worker-1")

    details = @service.system_health[:worker_stats][:worker_details]

    assert_equal 1, details.size
    assert_equal "worker-1", details.first[:hostname]
    # Generous delta: the age is measured when the service reads, not when the
    # row was written, so a contended CI worker can add seconds in between.
    assert_in_delta 296, details.first[:seconds_since_heartbeat], 15
  end

  test "worker_statistics does not report a hardcoded dispatcher count" do
    stats = @service.system_health[:worker_stats]

    refute stats.key?(:dispatchers),
      "GoodJob has no dispatchers; a hardcoded 0 reads as a signal on a healthy system"
  end

  test "system_health recent_errors includes error logs" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    session.logs.create!(content: "Test error message", level: "error")

    health = @service.system_health

    assert_equal 1, health[:recent_errors].size
    assert_includes health[:recent_errors].first[:content], "Test error message"
  end

  # === Cleanup Operations Tests ===

  test "cleanup_orphaned_processes returns results structure" do
    results = @service.cleanup_orphaned_processes

    assert results.key?(:terminated)
    assert results.key?(:failed)
    assert results.key?(:already_dead)
  end

  test "retry_failed_sessions returns results structure" do
    results = @service.retry_failed_sessions

    assert results.key?(:retried)
    assert results.key?(:failed)
    assert results.key?(:skipped)
  end

  test "retry_failed_sessions bulk path excludes sessions in a frozen category" do
    frozen = Session.create!(
      prompt: "parked", agent_runtime: "claude_code", status: :failed,
      git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem",
      category: Category.create!(name: "frozen-retry", is_frozen: true)
    )
    active = Session.create!(
      prompt: "active", agent_runtime: "claude_code", status: :failed,
      git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem"
    )

    results = @service.retry_failed_sessions

    considered = results[:retried] +
      results[:skipped].map { |r| r[:session_id] } +
      results[:failed].map { |r| r[:session_id] }

    assert_includes considered, active.id, "non-frozen failed session should be considered"
    assert_not_includes considered, frozen.id, "frozen-category session must be excluded from the bulk retry"
    assert_equal "failed", frozen.reload.status
  end

  test "retry_failed_sessions still targets an explicitly requested frozen session by id" do
    frozen = Session.create!(
      prompt: "parked", agent_runtime: "claude_code", status: :failed,
      git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem",
      category: Category.create!(name: "frozen-targeted", is_frozen: true)
    )

    results = @service.retry_failed_sessions(session_ids: [ frozen.id ])

    considered = results[:retried] +
      results[:skipped].map { |r| r[:session_id] } +
      results[:failed].map { |r| r[:session_id] }

    # Explicit id targeting bypasses the frozen-category exclusion by design.
    assert_includes considered, frozen.id
  end

  test "archive_old_sessions archives sessions older than threshold" do
    # Create old session
    old_session = Session.create!(
      prompt: "Old session",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    old_session.update_column(:updated_at, 10.days.ago)

    # Create recent session
    recent_session = Session.create!(
      prompt: "Recent session",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )

    results = @service.archive_old_sessions(older_than: 7.days)

    assert_includes results[:archived], old_session.id
    assert_not_includes results[:archived], recent_session.id

    old_session.reload
    assert old_session.archived?
  end

  # 2026-08-29: the stranded-queue alert dedups per session on purpose, so a
  # sweep that catches N sessions with queues posted N separate pages in one
  # tick — and every page in `#alerts` spawns its own triage session. The sweep
  # archives without consulting Sessions::ArchiveGuard, so those strands are
  # unforced and must stay loud; what they must not be is N messages.
  test "archive_old_sessions collapses a burst of stranded-queue alerts into one page" do
    stale = 2.times.map do |i|
      session = Session.create!(
        prompt: "Stale session #{i}",
        agent_runtime: "claude_code",
        status: :needs_input,
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        execution_provider: "local_filesystem"
      )
      session.enqueued_messages.create!(content: "queued for ##{session.id}", position: 1, status: "pending")
      session.update_column(:updated_at, 10.days.ago)
      session
    end

    # The environment gate is off in `test` and is covered by AlertServiceTest;
    # this is about how many messages one sweep produces. `emit` is what
    # AlertBatcher calls on flush, so counting it counts Slack posts.
    AlertService.stubs(:enabled?).returns(true)
    emitted = []
    # `once` is the assertion — one sweep owes the operator one page, not one
    # per session — so the count is enforced by Mocha at teardown rather than by
    # the capture, which is only here to let the body be inspected below.
    AlertService.expects(:emit).once.with do |title, options|
      emitted << [ title, options[:details] ]
      true
    end.returns(true)

    @service.archive_old_sessions(older_than: 7.days)

    title, details = emitted.last
    assert_equal "Queued messages stranded by an archive (\u00d72)", title
    stale.each do |session|
      assert_includes details, "Session #{session.id} was archived",
        "the aggregate still names every session it collapsed"
      assert_equal "undelivered", session.enqueued_messages.sole.status
    end
  end

  # === Overall Status Tests ===

  test "overall_status is healthy when all subsystems are healthy" do
    report = @service.full_health_report

    # With no sessions and no processes, everything should be healthy
    assert report[:overall_status].healthy?
  end

  test "overall_status is warning when any subsystem has warning" do
    # Create sessions with elevated failure rate (20%)
    8.times do |i|
      Session.create!(prompt: "Test #{i}", agent_runtime: "claude_code", status: :needs_input, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end
    2.times do |i|
      Session.create!(prompt: "Failed #{i}", agent_runtime: "claude_code", status: :failed, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end

    report = @service.full_health_report

    assert report[:overall_status].warning?
  end

  test "overall_status is critical when any subsystem is critical" do
    # Create sessions with high failure rate (40%)
    6.times do |i|
      Session.create!(prompt: "Test #{i}", agent_runtime: "claude_code", status: :needs_input, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end
    4.times do |i|
      Session.create!(prompt: "Failed #{i}", agent_runtime: "claude_code", status: :failed, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    end

    report = @service.full_health_report

    assert report[:overall_status].critical?
  end

  # === HealthStatus Struct Tests ===

  test "HealthStatus healthy? returns correct value" do
    healthy = HealthMonitorService::HealthStatus.new(status: :healthy, message: "OK")
    warning = HealthMonitorService::HealthStatus.new(status: :warning, message: "Warning")
    critical = HealthMonitorService::HealthStatus.new(status: :critical, message: "Critical")

    assert healthy.healthy?
    assert_not warning.healthy?
    assert_not critical.healthy?
  end

  test "HealthStatus warning? returns correct value" do
    healthy = HealthMonitorService::HealthStatus.new(status: :healthy, message: "OK")
    warning = HealthMonitorService::HealthStatus.new(status: :warning, message: "Warning")
    critical = HealthMonitorService::HealthStatus.new(status: :critical, message: "Critical")

    assert_not healthy.warning?
    assert warning.warning?
    assert_not critical.warning?
  end

  test "HealthStatus critical? returns correct value" do
    healthy = HealthMonitorService::HealthStatus.new(status: :healthy, message: "OK")
    warning = HealthMonitorService::HealthStatus.new(status: :warning, message: "Warning")
    critical = HealthMonitorService::HealthStatus.new(status: :critical, message: "Critical")

    assert_not healthy.critical?
    assert_not warning.critical?
    assert critical.critical?
  end

  # === Error Categorization Tests ===

  test "session_health categorizes timeout errors" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    session.logs.create!(content: "Connection timeout occurred", level: "error")

    health = @service.session_health

    assert_equal 1, health[:error_categories]["timeout"]
  end

  test "session_health categorizes permission errors" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    session.logs.create!(content: "Permission denied for operation", level: "error")

    health = @service.session_health

    assert_equal 1, health[:error_categories]["permission"]
  end

  test "session_health categorizes connection errors" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    session.logs.create!(content: "Connection refused", level: "error")

    health = @service.session_health

    assert_equal 1, health[:error_categories]["connection"]
  end

  test "session_health categorizes API errors" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    session.logs.create!(content: "API rate limit exceeded", level: "error")

    health = @service.session_health

    assert_equal 1, health[:error_categories]["api_error"]
  end

  # === SIGTERM Retry Health Tests ===

  test "sigterm_retry_health returns correct structure" do
    health = @service.sigterm_retry_health

    assert health.key?(:total_sigterm_sessions)
    assert health.key?(:total_retries_attempted)
    assert health.key?(:successful_recovery_count)
    assert health.key?(:exhausted_retry_count)
    assert health.key?(:recent_sigterm_count)
    assert health.key?(:rate_limit_pressure)
    assert health.key?(:rate_limit_events_5min)
    assert health.key?(:current_delay_mode)
    assert health.key?(:max_retries)
    assert health.key?(:recent_sigterm_sessions)
  end

  test "sigterm_retry_health counts sessions with SIGTERM retries" do
    # Create session with SIGTERM retry metadata
    Session.create!(
      prompt: "Test 1",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "sigterm_retry_count" => 2,
        "last_sigterm_at" => Time.current.iso8601
      }
    )

    # Create session without SIGTERM metadata
    Session.create!(
      prompt: "Test 2",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )

    health = @service.sigterm_retry_health

    assert_equal 1, health[:total_sigterm_sessions]
    assert_equal 2, health[:total_retries_attempted]
  end

  test "sigterm_retry_health counts successful recoveries" do
    # Create session that recovered from SIGTERM (has retry count but not failed)
    Session.create!(
      prompt: "Recovered",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "sigterm_retry_count" => 1,
        "last_sigterm_at" => Time.current.iso8601
      }
    )

    # Create failed session with SIGTERM retries
    Session.create!(
      prompt: "Failed",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "sigterm_retry_count" => 2,
        "last_sigterm_at" => Time.current.iso8601
      }
    )

    health = @service.sigterm_retry_health

    assert_equal 1, health[:successful_recovery_count]
  end

  test "sigterm_retry_health counts exhausted retries" do
    # Create session that exhausted retries (failed with retry count >= MAX_RETRIES)
    Session.create!(
      prompt: "Exhausted",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "sigterm_retry_count" => 3,
        "last_sigterm_at" => Time.current.iso8601
      }
    )

    # Create failed session but with fewer retries (not exhausted)
    Session.create!(
      prompt: "Failed but not exhausted",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "sigterm_retry_count" => 1,
        "last_sigterm_at" => Time.current.iso8601
      }
    )

    health = @service.sigterm_retry_health

    assert_equal 1, health[:exhausted_retry_count]
  end

  test "sigterm_retry_health tracks recent SIGTERM events in last 24 hours" do
    # Create recent SIGTERM session
    recent_session = Session.create!(
      prompt: "Recent",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      title: "Recent SIGTERM Session",
      metadata: {
        "sigterm_retry_count" => 1,
        "last_sigterm_at" => 1.hour.ago.iso8601
      }
    )

    # Create old SIGTERM session (more than 24 hours ago)
    Session.create!(
      prompt: "Old",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      title: "Old SIGTERM Session",
      metadata: {
        "sigterm_retry_count" => 1,
        "last_sigterm_at" => 2.days.ago.iso8601
      }
    )

    health = @service.sigterm_retry_health

    assert_equal 1, health[:recent_sigterm_count]
    assert_equal 1, health[:recent_sigterm_sessions].size
    # Verify we got the recent session (the one with last_sigterm_at within 24 hours)
    assert_equal recent_session.id, health[:recent_sigterm_sessions].first[:id]
  end

  test "sigterm_retry_health returns max_retries constant" do
    health = @service.sigterm_retry_health

    assert_equal RetryBudget::SIGTERM.max, health[:max_retries]
  end

  test "sigterm_retry_health reports normal delay mode when not under pressure" do
    health = @service.sigterm_retry_health

    assert_equal false, health[:rate_limit_pressure]
    assert_equal "normal", health[:current_delay_mode]
  end

  test "full_health_report includes sigterm_retry_health section" do
    report = @service.full_health_report

    assert report.key?(:sigterm_retry_health)
    assert report[:sigterm_retry_health].key?(:total_sigterm_sessions)
    assert report[:sigterm_retry_health].key?(:rate_limit_pressure)
  end

  test "sigterm_retry_health handles corrupted timestamp data gracefully" do
    # Create session with invalid timestamp string
    Session.create!(
      prompt: "Corrupted timestamp",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "sigterm_retry_count" => 1,
        "last_sigterm_at" => "not-a-valid-timestamp"
      }
    )

    # Should not raise error and should return nil for the timestamp
    assert_nothing_raised do
      health = @service.sigterm_retry_health
      # The session has sigterm_retry_count so should be counted
      assert_equal 1, health[:total_sigterm_sessions]
      assert_equal 1, health[:total_retries_attempted]
      # But it should NOT appear in recent_sigterm_sessions because
      # the invalid timestamp can't be parsed/compared by PostgreSQL
      # (SQL casting fails silently, returning no rows)
      assert_equal 0, health[:recent_sigterm_count]
    end
  end

  test "retry_budget_session_summary handles nil timestamp" do
    session = Session.create!(
      prompt: "No timestamp",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "sigterm_retry_count" => 1
      }
    )

    summary = @service.send(:retry_budget_session_summary, session, RetryBudget::SIGTERM)

    assert_nil summary[:last_attempt_at]
    assert_equal 1, summary[:retry_count]
  end

  # === Retry Budget Health Tests (issue #527) ===

  test "retry_budget_health covers every declared budget, not the two that were wired" do
    health = @service.retry_budget_health

    assert_equal RetryBudget.all.map(&:name), health[:budgets].map { |b| b[:name] }
    # The three that no health surface used to report at all.
    assert_includes health[:budgets].map { |b| b[:name] }, :signal_death
    assert_includes health[:budgets].map { |b| b[:name] }, :mcp_connection
    assert_includes health[:budgets].map { |b| b[:name] }, :context_length
  end

  test "retry_budget_health reports each budget's declared key and maximum" do
    health = @service.retry_budget_health
    by_name = health[:budgets].index_by { |b| b[:name] }

    assert_equal "mcp_retry_count", by_name[:mcp_connection][:count_key]
    assert_equal "mcp_last_retry_at", by_name[:mcp_connection][:stamp_key]
    assert_equal 3, by_name[:mcp_connection][:max_retries]
    assert_equal "compact_retry_count", by_name[:context_length][:count_key]
    assert_equal 2, by_name[:context_length][:max_retries]
    assert_equal 6, by_name[:api_error][:max_retries]
  end

  test "retry_budget_health counts spend, recoveries, exhaustion and recency per budget" do
    Session.create!(
      prompt: "Recovered from a failed MCP handshake", agent_runtime: "claude_code",
      status: :running, git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "mcp_retry_count" => 1, "mcp_last_retry_at" => 2.hours.ago.iso8601 }
    )
    Session.create!(
      prompt: "Burned the whole MCP budget", agent_runtime: "claude_code",
      status: :failed, git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "mcp_retry_count" => 3, "mcp_last_retry_at" => 30.hours.ago.iso8601 }
    )

    budget = @service.retry_budget_health[:budgets].find { |b| b[:name] == :mcp_connection }

    assert_equal 2, budget[:total_sessions]
    assert_equal 4, budget[:total_retries_attempted]
    assert_equal 1, budget[:successful_recovery_count]
    assert_equal 1, budget[:exhausted_retry_count]
    assert_equal 1, budget[:recent_count], "only the 2-hours-ago attempt is inside the 24h window"
    assert_equal 1, budget[:recent_sessions].size
    assert_equal 1, budget[:recent_sessions].first[:retry_count]
  end

  test "retry_budget_health reads a corrupt timestamp as no recent event rather than raising" do
    Session.create!(
      prompt: "Corrupt compact stamp", agent_runtime: "claude_code",
      status: :needs_input, git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "compact_retry_count" => 1, "last_compact_at" => "not-a-valid-timestamp" }
    )

    budget = @service.retry_budget_health[:budgets].find { |b| b[:name] == :context_length }

    assert_equal 1, budget[:total_sessions]
    assert_equal 0, budget[:recent_count]
    assert_empty budget[:recent_sessions]
  end

  test "full_health_report carries the retry_budget_health section" do
    report = @service.full_health_report

    assert report.key?(:retry_budget_health)
    assert_equal 5, report[:retry_budget_health][:budgets].size
  end

  # === API Error Retry Health Tests ===

  test "api_error_retry_health returns correct structure" do
    health = @service.api_error_retry_health

    assert health.key?(:total_api_error_sessions)
    assert health.key?(:total_retries_attempted)
    assert health.key?(:successful_recovery_count)
    assert health.key?(:exhausted_retry_count)
    assert health.key?(:rate_limit_pressure)
    assert health.key?(:rate_limit_events_5min)
    assert health.key?(:current_delay_mode)
    assert health.key?(:max_retries)
    assert health.key?(:recent_api_error_sessions)
  end

  test "api_error_retry_health counts sessions with API error retries" do
    Session.create!(
      prompt: "Test API error",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "api_error_retry_count" => 3,
        "last_api_error_retry_at" => Time.current.iso8601
      }
    )

    health = @service.api_error_retry_health

    assert_equal 1, health[:total_api_error_sessions]
    assert_equal 3, health[:total_retries_attempted]
  end

  test "api_error_retry_health counts successful recoveries" do
    Session.create!(
      prompt: "Recovered from API error",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "api_error_retry_count" => 2,
        "last_api_error_retry_at" => Time.current.iso8601
      }
    )

    health = @service.api_error_retry_health

    assert_equal 1, health[:successful_recovery_count]
  end

  test "api_error_retry_health counts exhausted retries" do
    Session.create!(
      prompt: "Exhausted API error retries",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "api_error_retry_count" => 6,
        "last_api_error_retry_at" => Time.current.iso8601
      }
    )

    health = @service.api_error_retry_health

    assert_equal 1, health[:exhausted_retry_count]
  end

  test "api_error_retry_health returns max_retries constant" do
    health = @service.api_error_retry_health

    assert_equal RetryBudget::API_ERROR.max, health[:max_retries]
  end

  test "full_health_report includes api_error_retry_health section" do
    report = @service.full_health_report

    assert report.key?(:api_error_retry_health)
    assert report[:api_error_retry_health].key?(:total_api_error_sessions)
    assert report[:api_error_retry_health].key?(:rate_limit_pressure)
  end

  # === Failure Reason Distribution Tests ===

  test "session_health includes failure_reasons key" do
    health = @service.session_health

    assert health.key?(:failure_reasons)
  end

  test "failure_reason_distribution returns counts by failure reason" do
    # Create sessions with different failure reasons
    Session.create!(
      prompt: "Git clone failed",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "failure_reason" => "git_clone_failed" }
    )

    Session.create!(
      prompt: "Process failed",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "failure_reason" => "process_failed", "exit_status" => "exit code: 1" }
    )

    Session.create!(
      prompt: "Another process failed",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "failure_reason" => "process_failed", "exit_status" => "exit code: 1" }
    )

    health = @service.session_health

    assert_equal 2, health[:failure_reasons]["process_failed"]
    assert_equal 1, health[:failure_reasons]["git_clone_failed"]
  end

  test "failure_reason_distribution counts unknown for sessions without failure_reason" do
    # Create session with no failure_reason in metadata
    Session.create!(
      prompt: "Unknown failure",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {}
    )

    # Create session with failure_reason set
    Session.create!(
      prompt: "Known failure",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "failure_reason" => "exception" }
    )

    health = @service.session_health

    assert_equal 1, health[:failure_reasons]["unknown"]
    assert_equal 1, health[:failure_reasons]["exception"]
  end

  test "failure_reason_distribution only includes last 24 hours" do
    # Create old failure (more than 24 hours ago)
    old_session = Session.create!(
      prompt: "Old failure",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "failure_reason" => "old_reason" }
    )
    old_session.update_column(:updated_at, 2.days.ago)

    # Create recent failure
    Session.create!(
      prompt: "Recent failure",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "failure_reason" => "recent_reason" }
    )

    health = @service.session_health

    assert_nil health[:failure_reasons]["old_reason"]
    assert_equal 1, health[:failure_reasons]["recent_reason"]
  end

  test "failure_reason_distribution sorts by count descending" do
    # Create multiple sessions with different failure reasons
    3.times do
      Session.create!(
        prompt: "Process failed",
        agent_runtime: "claude_code",
        status: :failed,
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        execution_provider: "local_filesystem",
        metadata: { "failure_reason" => "process_failed" }
      )
    end

    2.times do
      Session.create!(
        prompt: "Clone failed",
        agent_runtime: "claude_code",
        status: :failed,
        git_root: "https://github.com/test/repo.git",
        branch: "main",
        execution_provider: "local_filesystem",
        metadata: { "failure_reason" => "git_clone_failed" }
      )
    end

    Session.create!(
      prompt: "Exception",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "failure_reason" => "exception" }
    )

    health = @service.session_health

    # First key should be the most common reason
    assert_equal "process_failed", health[:failure_reasons].keys.first
    assert_equal 3, health[:failure_reasons].values.first
  end

  # === calculate_average_session_duration tests ===

  test "calculate_average_session_duration returns nil when no completed sessions" do
    assert_nil @service.send(:calculate_average_session_duration)
    assert_nil @service.session_health[:average_duration_seconds]
  end

  test "calculate_average_session_duration averages duration in seconds across completed sessions" do
    # 60s duration
    s1 = Session.create!(
      prompt: "Done",
      agent_runtime: "claude_code",
      status: :archived,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    s1.update_columns(created_at: 120.seconds.ago, updated_at: 60.seconds.ago)

    # 120s duration
    s2 = Session.create!(
      prompt: "Idle",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    s2.update_columns(created_at: 240.seconds.ago, updated_at: 120.seconds.ago)

    # Average of 60s and 120s == 90s
    assert_equal 90, @service.send(:calculate_average_session_duration)
  end

  test "calculate_average_session_duration rounds a half-second average half away from zero" do
    # Two sessions: 1s and 2s → average 1.5s, which must round up to 2 (matching
    # Ruby Float#round), not down to 2-via-banker's-rounding ambiguity.
    s1 = Session.create!(
      prompt: "One",
      agent_runtime: "claude_code",
      status: :archived,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    s1.update_columns(created_at: 11.seconds.ago, updated_at: 10.seconds.ago)

    s2 = Session.create!(
      prompt: "Two",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    s2.update_columns(created_at: 12.seconds.ago, updated_at: 10.seconds.ago)

    # Average of 1s and 2s == 1.5s, rounded half away from zero == 2
    assert_equal 2, @service.send(:calculate_average_session_duration)
  end

  test "calculate_average_session_duration only includes archived and needs_input within 7 days" do
    # In-window archived session: 100s
    in_window = Session.create!(
      prompt: "Recent",
      agent_runtime: "claude_code",
      status: :archived,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    in_window.update_columns(created_at: 200.seconds.ago, updated_at: 100.seconds.ago)

    # Out-of-window archived session (updated_at > 7 days ago) — excluded
    old = Session.create!(
      prompt: "Old",
      agent_runtime: "claude_code",
      status: :archived,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    old.update_columns(created_at: 10.days.ago, updated_at: 8.days.ago)

    # Wrong-status session (running) — excluded regardless of recency
    running = Session.create!(
      prompt: "Running",
      agent_runtime: "claude_code",
      status: :running,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    )
    running.update_columns(created_at: 1000.seconds.ago, updated_at: 1.second.ago)

    # Only the in-window archived session counts: 100s
    assert_equal 100, @service.send(:calculate_average_session_duration)
  end

  test "session_summary includes failure_reason from metadata" do
    session = Session.create!(
      prompt: "Failed session",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: { "failure_reason" => "sigterm_retries_exhausted" }
    )

    summary = @service.send(:session_summary, session)

    assert_equal "sigterm_retries_exhausted", summary[:failure_reason]
  end

  test "session_summary returns nil failure_reason when not set" do
    session = Session.create!(
      prompt: "Failed session",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {}
    )

    summary = @service.send(:session_summary, session)

    assert_nil summary[:failure_reason]
  end

  private

  # Build a GoodJob process row whose heartbeat is a given age. updated_at is
  # managed by Rails, so it has to be written past the timestamp callbacks.
  def create_good_job_process(seconds_since_heartbeat:, hostname: "test-host")
    process = GoodJob::Process.create!(state: { "hostname" => hostname })
    process.update_column(:updated_at, seconds_since_heartbeat.seconds.ago)
    process
  end
  # ── issue #618, hole 5: corruption had no health surface ─────────────

  test "auth_health reports a corrupt worker credentials file as critical" do
    ClaudeCredentialHealth.stubs(:status).returns(
      ClaudeCredentialHealth::Status.new(state: :corrupt, detail: "tokens blanked", owner_email: "a@b.com", checked_at: Time.current)
    )

    auth = HealthMonitorService.new.auth_health

    assert auth[:status].critical?
    assert_equal :corrupt, auth[:credentials_state]
    assert_equal "a@b.com", auth[:credentials_owner]
  end

  test "auth_health is healthy when the file is intact and the pool has an account" do
    ClaudeCredentialHealth.stubs(:status).returns(
      ClaudeCredentialHealth::Status.new(state: :ok, detail: "fine", owner_email: "a@b.com", checked_at: Time.current)
    )

    auth = HealthMonitorService.new.auth_health

    assert auth[:status].healthy?
    assert auth[:available_accounts].positive?
  end

  # The contradiction that started this: at 02:06Z on 2026-08-23 the parking
  # decision declared the whole pool quota-exhausted and put four sessions to
  # sleep; at 02:13Z this card reported "3 Claude accounts available". Both were
  # reading the sticky `status` column, minutes apart, and the healer moved it in
  # between. They ask one predicate now, so they cannot disagree.
  test "auth_health and the parking decision answer from the same predicate" do
    ClaudeCredentialHealth.stubs(:status).returns(
      ClaudeCredentialHealth::Status.new(state: :ok, detail: "fine", owner_email: "a@b.com", checked_at: Time.current)
    )
    # Every account labelled quota_exceeded, every account's own reading newer
    # than the label and clear — the state the production pool was in at 02:06Z.
    ClaudeAccount.for_runtime("claude_code").update_all(status: ClaudeAccount.statuses[:quota_exceeded])
    ClaudeAccount.for_runtime("claude_code").find_each do |account|
      account.quota_snapshots.create!(trigger: "rotation", status_5h: "allowed", status_7d: "allowed",
        utilization_5h: 0.35, reset_5h: 26.minutes.from_now,
        utilization_7d: 0.12, reset_7d: 6.days.from_now)
    end

    auth = HealthMonitorService.new.auth_health

    assert_equal 0, auth[:available_accounts], "nothing can be spawned on right now"
    assert auth[:serviceable_accounts].positive?, "but the readings say the pool can serve"
    assert_equal ClaudeAccount.serviceable_for("claude_code").count, auth[:serviceable_accounts],
      "the card and the park decision must read one predicate"

    assert auth[:status].warning?,
      "a pool nothing can spawn against is not healthy, however good its readings are"
    assert_match(/reset checker restores them/, auth[:status].message)
  end

  test "auth_health reports a healthy pool from the column, not the evidence" do
    ClaudeCredentialHealth.stubs(:status).returns(
      ClaudeCredentialHealth::Status.new(state: :ok, detail: "fine", owner_email: "a@b.com", checked_at: Time.current)
    )

    auth = HealthMonitorService.new.auth_health

    assert auth[:status].healthy?
    assert_equal ClaudeAccount.available.for_runtime(ClaudeAuthProvider::RUNTIME).count,
      auth[:available_accounts]
    assert_match(/Claude accounts? available/, auth[:status].message)
  end

  test "auth_health warns when nothing is serviceable at all" do
    ClaudeCredentialHealth.stubs(:status).returns(
      ClaudeCredentialHealth::Status.new(state: :ok, detail: "fine", owner_email: "a@b.com", checked_at: Time.current)
    )
    ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME)
      .update_all(status: ClaudeAccount.statuses[:needs_reauth])

    auth = HealthMonitorService.new.auth_health

    assert auth[:status].warning?
    assert_equal 0, auth[:serviceable_accounts]
    assert_match(/No Claude account is available/, auth[:status].message)
  end

  test "a corrupt credentials file makes the overall status critical" do
    ClaudeCredentialHealth.stubs(:status).returns(
      ClaudeCredentialHealth::Status.new(state: :corrupt, detail: "tokens blanked", owner_email: "a@b.com", checked_at: Time.current)
    )

    assert HealthMonitorService.new.full_health_report[:overall_status].critical?
  end
end
