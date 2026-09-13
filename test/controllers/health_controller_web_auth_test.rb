# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The auth posture of /health's web actions: none, like the rest of the web UI. The
# mutating POSTs answer without a credential and without a challenge. Their REST twins
# under /api/v1/health require an API key, and that is asserted here too, because
# the two surfaces are easy to confuse.
class HealthControllerWebAuthTest < ActionDispatch::IntegrationTest
  # Every mutating POST on /health, with a params payload that reaches the action rather
  # than tripping a validation first. `every POST /health route is in this test's list`
  # fails if a route is added to the controller and not here.
  MUTATING = {
    cleanup_processes: [ :cleanup_processes_health_path, {} ],
    retry_sessions: [ :retry_sessions_health_path, {} ],
    archive_old: [ :archive_old_health_path, { days: 7 } ],
    enter_queue_recovery_mode: [ :enter_queue_recovery_mode_health_path, { reason: "test", ttl_minutes: 30 } ],
    exit_queue_recovery_mode: [ :exit_queue_recovery_mode_health_path, {} ],
    run_post_deploy_tasks: [ :run_post_deploy_tasks_health_path, {} ],
    # Scoped and count-confirmed so the action reaches the service. There is nothing
    # queued in this suite, so expected_count is 0 and the call is a no-op.
    discard_queued_jobs: [ :discard_queued_jobs_health_path, { queue_name: "pollers", expected_count: 0 } ],
    reschedule_queued_jobs: [ :reschedule_queued_jobs_health_path, { queue_name: "pollers", expected_count: 0 } ]
  }.freeze

  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    ErrorReporter.stubs(:report_message)

    AppSetting.delete_all
    GoodJob::Setting.delete_all

    # The cooldown fails closed when the cache cannot enforce it, and the test env's
    # null_store cannot — which would answer 503 and mask what this file is about.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ApplicationController.recovery_mode_reconciled_at = nil
  end

  teardown do
    Rails.cache.clear
    Rails.cache = @original_cache
    GoodJob::Setting.delete_all
    ApplicationController.recovery_mode_reconciled_at = nil
  end

  MUTATING.each do |action, (path_helper, params)|
    test "#{action} is served without a credential" do
      post send(path_helper), params: params

      assert_redirected_to health_dashboard_path
      assert_nil response.headers["WWW-Authenticate"]
    end
  end

  test "every POST /health route is in this test's list" do
    posted_actions = Rails.application.routes.routes.filter_map do |route|
      next unless route.defaults[:controller] == "health"
      next unless route.verb == "POST"

      route.defaults[:action].to_sym
    end.uniq

    assert_equal MUTATING.keys.sort, posted_actions.sort
  end

  # With no credential, CSRF is what keeps a page on another origin from submitting
  # these forms from a human's browser.
  test "a POST without a CSRF token is refused and changes nothing" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post enter_queue_recovery_mode_health_path, params: { reason: "forged", ttl_minutes: 30 }

    assert_response :unprocessable_entity
    assert_not QueueRecoveryMode.active?
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "the read-only surfaces are anonymous" do
    get health_dashboard_path
    assert_response :success

    get refresh_health_path
    assert_response :success

    get export_diagnostics_health_path, headers: { "Accept" => "application/json" }
    assert_response :success

    # The two the deploy's health gate hits. A 401 on either fails every cutover.
    get "/up"
    assert_response :success

    get deep_health_check_path
    assert_includes [ 200, 503 ], response.status
  end

  # Only the web dashboard is open. The REST twin keeps its own credential.
  test "the REST twin requires an API key" do
    original_keys = ENV["API_KEYS"]
    ENV["API_KEYS"] = "test_api_key_health_gate"

    post cleanup_processes_api_v1_health_path
    assert_response :unauthorized

    post cleanup_processes_api_v1_health_path, headers: { "X-API-Key" => "test_api_key_health_gate" }
    assert_response :success
  ensure
    original_keys.nil? ? ENV.delete("API_KEYS") : ENV["API_KEYS"] = original_keys
  end
end
