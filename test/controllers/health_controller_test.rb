# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class HealthControllerTest < ActionDispatch::IntegrationTest
  def setup
    # Stub Turbo Stream broadcasting to avoid missing partial errors in tests
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    # Use memory cache for rate limiting tests (test env uses null_store by default)
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  def teardown
    Mocha::Mockery.instance.teardown
    # Clear rate limiting cache. The cooldown keys are built by
    # HealthActionCooldown now, so clear the store rather than naming them.
    Rails.cache.clear
    # Restore original cache
    Rails.cache = @original_cache
  end

  # === Deep health check (GET /up/deep) ===

  # Whether a Redis happens to be reachable from the test runner must not decide
  # these assertions -- with REDIS_URL unset the redis check reports `skipped`,
  # which is not a failure. The Redis branches themselves are exercised in
  # test/services/deep_health_check_test.rb.
  def without_redis_url
    original = ENV["REDIS_URL"]
    ENV.delete("REDIS_URL")
    yield
  ensure
    ENV["REDIS_URL"] = original
  end

  test "deep health check answers 200 with a per-component report when healthy" do
    without_redis_url { get deep_health_check_url }

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "ok", json["status"]
    assert_empty json["failed"]
    assert_equal "ok", json.dig("checks", "database", "status")
    assert_equal "ok", json.dig("checks", "cache", "status")
    assert json["checks"].key?("redis")
    assert json["checked_at"].present?
  end

  # The whole point of the endpoint: a broken backing service must be a RED
  # answer, because `/up` returns 200 for exactly this container.
  test "deep health check answers 503 and names the failed component" do
    Rails.cache = ActiveSupport::Cache::NullStore.new

    without_redis_url { get deep_health_check_url }

    assert_response :service_unavailable
    json = JSON.parse(response.body)
    assert_equal "error", json["status"]
    assert_equal [ "cache" ], json["failed"]
    assert_match(/NullStore/, json.dig("checks", "cache", "error"))
  end

  test "deep health check answers 503 when the database cannot answer" do
    ActiveRecord::Base.connection.stubs(:select_value).raises(ActiveRecord::StatementInvalid, "PG::ConnectionBad")

    without_redis_url { get deep_health_check_url }

    assert_response :service_unavailable
    json = JSON.parse(response.body)
    assert_equal [ "database" ], json["failed"]
  end

  # It is a health endpoint, not a maintenance action: HealthActionCooldown
  # fails closed under an unusable cache, which would answer "rate limited" for
  # precisely the broken-cache case this exists to report.
  test "deep health check is not rate limited" do
    without_redis_url do
      3.times do
        get deep_health_check_url
        assert_response :success
      end
    end
  end

  # === Dashboard Tests ===

  test "should get dashboard" do
    get health_dashboard_url
    assert_response :success
    assert_select "h1", text: "System Health Dashboard"
  end

  test "dashboard displays health sections" do
    get health_dashboard_url
    assert_response :success

    # Check for main section headings
    assert_select "h3", text: "Process Health"
    assert_select "h3", text: "Session Health"
    assert_select "h3", text: "System Health"
    assert_select "h3", text: "Maintenance Actions"
  end

  # UI/MCP parity for cron freshness: `get_system_health` names the keys that stopped
  # producing jobs and why, and this card is where /health says the same.
  test "dashboard lists a stale cron key with its reason" do
    GoodJob::CronEntry.stubs(:all).returns([
      GoodJob::CronEntry.new(key: :docker_cleanup, cron: "0 */6 * * *", class: "DockerCleanupJob"),
      GoodJob::CronEntry.new(key: :zombie_reaper, cron: "*/5 * * * *", class: "ZombieReaperJob")
    ])
    GoodJob::Process.insert_all([
      { id: SecureRandom.uuid, state: { cron_enabled: true }, created_at: 2.days.ago, updated_at: Time.current }
    ])
    hung = 9.hours.ago
    GoodJob::Job.insert_all([
      { queue_name: "maintenance", job_class: "DockerCleanupJob", cron_key: "docker_cleanup", cron_at: hung,
        created_at: hung, updated_at: hung, scheduled_at: hung, performed_at: hung,
        locked_by_id: SecureRandom.uuid, locked_at: hung, finished_at: nil }
    ])
    # ZombieReaperJob ticked every five minutes throughout, which is also the evidence that a
    # cron manager was running at the six-hourly tick DockerCleanupJob owes.
    last_tick = Time.current.beginning_of_minute - (Time.current.min % 5).minutes
    GoodJob::Job.insert_all(Array.new(120) do |i|
      at = last_tick - (i * 5).minutes
      { queue_name: "default", job_class: "ZombieReaperJob", cron_key: "zombie_reaper", cron_at: at,
        created_at: at, updated_at: at, scheduled_at: at, performed_at: at,
        locked_by_id: nil, locked_at: nil, finished_at: at + 1 }
    end)

    get health_dashboard_url
    assert_response :success

    assert_select "h3", text: "Cron Freshness"
    assert_match "Cron schedule stale: 1 key(s) stopped producing jobs (docker_cleanup)", response.body
    assert_match(/Held by a run on maintenance that started 9h 0m ago and has not finished/, response.body)
    assert_select "summary", text: /Every key \(2\)/
  end

  # The reading the card exists for that nothing else on the page shows: a key whose
  # newest tick is current, so every live signal says `fresh`, and which was silent for
  # six hours earlier in the window. Its own summary line is INFO, and the OTel appender
  # ships WARN and above, so the log store cannot answer it either (tadasant/zimmer#584).
  test "dashboard shows a cron key that stopped earlier in the window and recovered" do
    GoodJob::CronEntry.stubs(:all).returns([
      GoodJob::CronEntry.new(key: :zombie_reaper, cron: "*/5 * * * *", class: "ZombieReaperJob")
    ])
    GoodJob::Process.insert_all([
      { id: SecureRandom.uuid, state: { cron_enabled: true }, created_at: 2.days.ago, updated_at: Time.current }
    ])
    last_tick = Time.current.beginning_of_minute - (Time.current.min % 5).minutes
    ticks = (0..359).reject { |i| (48..119).cover?(i) } # a 6h 5m silence, from 10h ago to 4h ago
    GoodJob::Job.insert_all(ticks.map do |i|
      at = last_tick - (i * 5).minutes
      { queue_name: "default", job_class: "ZombieReaperJob", cron_key: "zombie_reaper", cron_at: at,
        created_at: at, updated_at: at, scheduled_at: at, finished_at: at + 1 }
    end)

    get health_dashboard_url
    assert_response :success

    assert_match(/1 key\(s\) stopped and recovered in the last 24 hours/, response.body)
    assert_match(%r{zombie_reaper</span> is enqueuing now, but was silent\s+6h 5m\s+until}, response.body)
    assert_match(/title="silent 6h 5m"/, response.body)
  end

  test "dashboard displays overall status" do
    get health_dashboard_url
    assert_response :success

    # Should show status message
    assert_match /All systems operational|issues detected|warnings detected/, response.body
  end

  # UI/MCP parity. The `get_system_health` MCP tool answers "which lane is deep"
  # and "what is filling it", and this panel is where /health answers them too — on
  # the page a human opens when the backlog alert fires. Without it the dashboard
  # shows four bare totals and says strictly less than the agent surface (#450).
  test "dashboard shows what the backlog is made of, not just how deep it is" do
    now = Time.current
    blank = { queue_name: nil, job_class: nil, scheduled_at: nil, locked_by_id: nil, locked_at: nil,
              performed_at: nil, created_at: now, updated_at: now }
    GoodJob::Job.insert_all(
      Array.new(6) do
        blank.merge(queue_name: "inference", job_class: "SessionStatusSummaryJob",
                    scheduled_at: 20.minutes.ago)
      end +
      Array.new(2) do
        blank.merge(queue_name: "default", job_class: "SessionTitleJob", scheduled_at: 1.minute.ago)
      end +
      [ blank.merge(queue_name: "agents", job_class: "AgentSessionJob", locked_by_id: SecureRandom.uuid,
                    locked_at: 30.seconds.ago, performed_at: 30.seconds.ago) ]
    )

    get health_dashboard_url
    assert_response :success

    assert_select "h4", text: "Backlog Breakdown"
    assert_select "dd", text: /inference 6, default 2/
    assert_select "dd", text: /SessionStatusSummaryJob 6, SessionTitleJob 2/
    assert_select "dd", text: /inference 20m, default 1m/
    assert_select "dd", text: /inference \/ SessionStatusSummaryJob, waiting 20m/
    assert_select "dd", text: /agents 1/
    assert_select "dd", text: /AgentSessionJob 1/
  end

  # A breakdown of an empty queue is a block of noise on a healthy dashboard, and
  # the section has nothing to say when nothing is waiting or running.
  test "dashboard omits the backlog breakdown when the queues are empty" do
    get health_dashboard_url
    assert_response :success

    assert_select "h4", text: "Backlog Breakdown", count: 0
  end

  test "dashboard links back to sessions" do
    get health_dashboard_url
    assert_response :success

    assert_select "a[href='#{root_path}']", text: /Back to Sessions/
  end

  # === Refresh Tests ===

  test "refresh returns html partial" do
    get refresh_health_url, headers: { "Accept" => "text/html" }
    assert_response :success
    assert_match /Process Health/, response.body
  end

  test "refresh returns json" do
    get refresh_health_url, headers: { "Accept" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("process_health")
    assert json.key?("session_health")
    assert json.key?("system_health")
    assert json.key?("overall_status")
  end

  # === Cleanup Processes Tests ===

  # This action really terminates processes, and the orphan test it uses — a live
  # `claude` process this uid owns that no running session in the database records
  # — matches every live agent on the host when the database is the test one. It
  # killed the session running this file three times before the host scan was
  # made unreachable from the test environment (#1095). This case is the tripwire:
  # if a change lets the action reach the host again, this fails before anything
  # is signalled, because the expectations replace the methods.
  test "cleanup_processes never scans the host or terminates a process from a test" do
    HostProcessDiscovery.expects(:new).never
    ProcessTerminationService.any_instance.expects(:terminate).never

    post cleanup_processes_health_url, headers: { "Accept" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal [], json["terminated"]
    assert_equal [], json["failed"]
  end

  test "cleanup_processes redirects with notice" do
    post cleanup_processes_health_url
    assert_redirected_to health_dashboard_path
    assert flash[:notice].present?
  end

  test "cleanup_processes returns json" do
    post cleanup_processes_health_url, headers: { "Accept" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("terminated")
    assert json.key?("failed")
    assert json.key?("already_dead")
  end

  test "cleanup_processes is rate limited" do
    # Pre-populate cache to simulate a recent action
    HealthActionCooldown.new(nil).record("cleanup_processes")

    # Request should be rate limited
    post cleanup_processes_health_url
    assert_redirected_to health_dashboard_path
    assert_match /Please wait/, flash[:alert]
  end

  test "cleanup_processes rate limit returns json error" do
    # Pre-populate cache to simulate a recent action
    HealthActionCooldown.new(nil).record("cleanup_processes")

    # Request should be rate limited
    post cleanup_processes_health_url, headers: { "Accept" => "application/json" }
    assert_response :too_many_requests

    json = JSON.parse(response.body)
    assert_equal "Rate limited", json["error"]
    assert json["retry_after"].present?
  end

  # === Retry Sessions Tests ===

  test "retry_sessions redirects with notice" do
    post retry_sessions_health_url
    assert_redirected_to health_dashboard_path
    assert flash[:notice].present?
  end

  test "retry_sessions returns json" do
    post retry_sessions_health_url, headers: { "Accept" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("retried")
    assert json.key?("failed")
    assert json.key?("skipped")
  end

  test "retry_sessions accepts session_ids parameter" do
    # Create a failed session with required metadata for retry
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid
    )

    # Create temp working directory
    clone_path = Rails.root.join("tmp", "test_clone_retry_#{session.id}")
    FileUtils.mkdir_p(clone_path)
    session.update!(metadata: { "working_directory" => clone_path.to_s })

    post retry_sessions_health_url, params: { session_ids: [ session.id ] }
    assert_redirected_to health_dashboard_path

    # Cleanup
    FileUtils.rm_rf(clone_path)
  end

  # The HTML surface used to flash counts of `retried` and `failed` only, so a
  # session the claim refused — or one missing its working directory — came back
  # as "No sessions to retry" to an operator who had just asked for that exact
  # session by id. Indistinguishable from a bug.
  test "retry_sessions flashes why a session was skipped" do
    session = Session.create!(
      prompt: "Test",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: SecureRandom.uuid,
      metadata: { "working_directory" => "/nonexistent/clone/path" }
    )

    post retry_sessions_health_url, params: { session_ids: [ session.id ] }

    assert_redirected_to health_dashboard_path
    assert_match(/Skipped 1 session/, flash[:notice])
    assert_match(/Missing required metadata/, flash[:notice])
    assert_no_match(/No sessions to retry/, flash[:notice],
      "the operator asked for one specific session and must be told what happened to it")
    assert_nil flash[:alert], "a skip is not a failure — the bulk sweep skips routinely"
  end

  test "retry_sessions is rate limited" do
    # Pre-populate cache to simulate a recent action
    HealthActionCooldown.new(nil).record("retry_sessions")

    # Request should be rate limited
    post retry_sessions_health_url
    assert_redirected_to health_dashboard_path
    assert_match /Please wait/, flash[:alert]
  end

  # === Archive Old Tests ===

  test "archive_old redirects with notice" do
    post archive_old_health_url
    assert_redirected_to health_dashboard_path
    assert flash[:notice].present?
  end

  test "archive_old returns json" do
    post archive_old_health_url, headers: { "Accept" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("archived")
    assert json.key?("failed")
  end

  test "archive_old accepts days parameter" do
    # Create an old session
    session = Session.create!(
      prompt: "Old session",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
    session.update_column(:updated_at, 10.days.ago)

    post archive_old_health_url, params: { days: 7 }
    assert_redirected_to health_dashboard_path

    session.reload
    assert session.archived?
  end

  test "archive_old does not archive recent sessions" do
    # Create a recent session
    session = Session.create!(
      prompt: "Recent session",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    post archive_old_health_url, params: { days: 7 }

    session.reload
    assert_not session.archived?
  end

  test "archive_old is rate limited" do
    # Pre-populate cache to simulate a recent action
    HealthActionCooldown.new(nil).record("archive_old")

    # Request should be rate limited
    post archive_old_health_url
    assert_redirected_to health_dashboard_path
    assert_match /Please wait/, flash[:alert]
  end

  # === Fail closed when the cooldown cannot be enforced ===
  #
  # This surface used to no-op its limiter under a dead cache and run the action
  # anyway. It now refuses. The dashboard itself keeps rendering — only the
  # destructive actions are gated.

  test "cleanup_processes is refused when the cache cannot enforce the cooldown" do
    Rails.cache = ActiveSupport::Cache::NullStore.new
    HealthMonitorService.any_instance.expects(:cleanup_orphaned_processes).never

    post cleanup_processes_health_url

    assert_redirected_to health_dashboard_path
    assert_match(/cooldown cannot be enforced/, flash[:alert])
  end

  test "the refusal is a 503 for json callers" do
    Rails.cache = ActiveSupport::Cache::NullStore.new

    post archive_old_health_url, headers: { "Accept" => "application/json" }

    assert_response :service_unavailable
    assert_equal "Rate limiting unavailable", JSON.parse(response.body)["error"]
  end

  test "the dashboard still renders when the cache is unusable" do
    Rails.cache = ActiveSupport::Cache::NullStore.new

    get health_dashboard_url

    assert_response :success
  end

  # === Export Diagnostics Tests ===

  test "export_diagnostics returns json" do
    get export_diagnostics_health_url(format: :json)
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("health_report")
    assert json.key?("exported_at")
    assert json.key?("rails_env")
    assert json.key?("ruby_version")
  end

  test "export_diagnostics includes full health report" do
    get export_diagnostics_health_url(format: :json)

    json = JSON.parse(response.body)
    report = json["health_report"]

    assert report.key?("process_health")
    assert report.key?("session_health")
    assert report.key?("system_health")
    assert report.key?("overall_status")
  end

  # === Route Tests ===

  test "should route to dashboard" do
    assert_routing(
      { method: :get, path: "/health" },
      { controller: "health", action: "dashboard" }
    )
  end

  test "should route to refresh" do
    assert_routing(
      { method: :get, path: "/health/refresh" },
      { controller: "health", action: "refresh" }
    )
  end

  test "should route to cleanup_processes" do
    assert_routing(
      { method: :post, path: "/health/cleanup_processes" },
      { controller: "health", action: "cleanup_processes" }
    )
  end

  test "should route to retry_sessions" do
    assert_routing(
      { method: :post, path: "/health/retry_sessions" },
      { controller: "health", action: "retry_sessions" }
    )
  end

  test "should route to archive_old" do
    assert_routing(
      { method: :post, path: "/health/archive_old" },
      { controller: "health", action: "archive_old" }
    )
  end

  test "should route to export_diagnostics" do
    assert_routing(
      { method: :get, path: "/health/export_diagnostics" },
      { controller: "health", action: "export_diagnostics" }
    )
  end

  # === Session Stats Tests ===

  test "dashboard shows session statistics" do
    # Create sessions with different statuses
    Session.create!(prompt: "Running", agent_runtime: "claude_code", status: :running, git_root: "https://github.com/test/repo.git", branch: "main")
    Session.create!(prompt: "Failed", agent_runtime: "claude_code", status: :failed, git_root: "https://github.com/test/repo.git", branch: "main")

    get health_dashboard_url
    assert_response :success

    # Check that statistics are displayed
    assert_match /Total Sessions/, response.body
    assert_match /Failure Rate/, response.body
    assert_match /Status Distribution/, response.body
  end

  test "dashboard shows recent failures" do
    # Create a failed session
    session = Session.create!(
      prompt: "Failed task",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "My Failed Session"
    )
    session.logs.create!(content: "Something went wrong", level: "error")

    get health_dashboard_url
    assert_response :success

    # Check that failure is displayed
    assert_match /Recent Failures/, response.body
    assert_match /My Failed Session/, response.body
  end

  # === SIGTERM Retry Health Tests ===

  test "dashboard displays SIGTERM auto-retry section" do
    get health_dashboard_url
    assert_response :success

    assert_select "h3", text: "SIGTERM Auto-Retry"
  end

  test "dashboard shows SIGTERM retry statistics" do
    # Create session with SIGTERM retry metadata
    Session.create!(
      prompt: "Test with SIGTERM",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: {
        "sigterm_retry_count" => 2,
        "last_sigterm_at" => Time.current.iso8601
      }
    )

    get health_dashboard_url
    assert_response :success

    # Check that statistics are displayed
    assert_match /Recovered/, response.body
    assert_match /Exhausted/, response.body
    assert_match /Retry Statistics/, response.body
    assert_match /Rate Limit Status/, response.body
  end

  test "dashboard shows recent SIGTERM sessions table when present" do
    # Create session with recent SIGTERM
    Session.create!(
      prompt: "SIGTERM session",
      agent_runtime: "claude_code",
      status: :needs_input,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "My SIGTERM Session",
      metadata: {
        "sigterm_retry_count" => 1,
        "last_sigterm_at" => 1.hour.ago.iso8601
      }
    )

    get health_dashboard_url
    assert_response :success

    # Check that recent SIGTERM table is displayed
    assert_match /Recent SIGTERM Events/, response.body
    assert_match /My SIGTERM Session/, response.body
  end

  test "refresh includes sigterm_retry_health in json response" do
    get refresh_health_url, headers: { "Accept" => "application/json" }
    assert_response :success

    json = JSON.parse(response.body)
    assert json.key?("sigterm_retry_health")
    assert json["sigterm_retry_health"].key?("total_sigterm_sessions")
    assert json["sigterm_retry_health"].key?("rate_limit_pressure")
    assert json["sigterm_retry_health"].key?("current_delay_mode")
  end

  test "export_diagnostics includes sigterm_retry_health" do
    get export_diagnostics_health_url(format: :json)
    assert_response :success

    json = JSON.parse(response.body)
    report = json["health_report"]

    assert report.key?("sigterm_retry_health")
    assert report["sigterm_retry_health"].key?("max_retries")
  end
end
