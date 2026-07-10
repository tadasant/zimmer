# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

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

    assert_equal SigtermRetryService::MAX_RETRIES, health[:max_retries]
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

  test "sigterm_session_summary handles nil timestamp" do
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

    summary = @service.send(:sigterm_session_summary, session)

    assert_nil summary[:last_sigterm_at]
    assert_equal 1, summary[:retry_count]
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

    assert_equal ApiErrorRetryService::MAX_RETRIES, health[:max_retries]
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
end
