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
    # Clear rate limiting cache
    Rails.cache.delete("health_controller_rate_limit:cleanup_processes")
    Rails.cache.delete("health_controller_rate_limit:retry_sessions")
    Rails.cache.delete("health_controller_rate_limit:archive_old")
    # Restore original cache
    Rails.cache = @original_cache
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

  test "dashboard displays overall status" do
    get health_dashboard_url
    assert_response :success

    # Should show status message
    assert_match /All systems operational|issues detected|warnings detected/, response.body
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
    Rails.cache.write("health_controller_rate_limit:cleanup_processes", Time.current, expires_in: 31.seconds)

    # Request should be rate limited
    post cleanup_processes_health_url
    assert_redirected_to health_dashboard_path
    assert_match /Please wait/, flash[:alert]
  end

  test "cleanup_processes rate limit returns json error" do
    # Pre-populate cache to simulate a recent action
    Rails.cache.write("health_controller_rate_limit:cleanup_processes", Time.current, expires_in: 31.seconds)

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
      execution_provider: "local_filesystem",
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

  test "retry_sessions is rate limited" do
    # Pre-populate cache to simulate a recent action
    Rails.cache.write("health_controller_rate_limit:retry_sessions", Time.current, expires_in: 31.seconds)

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
      branch: "main",
      execution_provider: "local_filesystem"
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
      branch: "main",
      execution_provider: "local_filesystem"
    )

    post archive_old_health_url, params: { days: 7 }

    session.reload
    assert_not session.archived?
  end

  test "archive_old is rate limited" do
    # Pre-populate cache to simulate a recent action
    Rails.cache.write("health_controller_rate_limit:archive_old", Time.current, expires_in: 31.seconds)

    # Request should be rate limited
    post archive_old_health_url
    assert_redirected_to health_dashboard_path
    assert_match /Please wait/, flash[:alert]
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
    Session.create!(prompt: "Running", agent_runtime: "claude_code", status: :running, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")
    Session.create!(prompt: "Failed", agent_runtime: "claude_code", status: :failed, git_root: "https://github.com/test/repo.git", branch: "main", execution_provider: "local_filesystem")

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
      execution_provider: "local_filesystem",
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
      execution_provider: "local_filesystem",
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
      execution_provider: "local_filesystem",
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
