# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The gate on /health's mutating actions (#312, #371), asserted in both directions.
#
# An auth change on this route set fails silently either way: too tight and the operator's
# incident console goes dark, too loose and the hole is still there behind a change that
# looks like a fix. So every route is named here twice — refused without the credential,
# served with it — and the surfaces that must stay open are named too.
class HealthControllerOperatorAuthTest < ActionDispatch::IntegrationTest
  PASSWORD_ENV = OperatorHttpBasicAuth::PASSWORD_ENV
  USERNAME_ENV = OperatorHttpBasicAuth::USERNAME_ENV
  PASSWORD = "operator-gate-test-password"

  # Every mutating POST on /health, with a params payload that reaches the action rather
  # than tripping a validation first. If a route is added to the controller and not to this
  # list, `every mutating /health route is in this test's list` fails.
  GATED = {
    cleanup_processes: [ :cleanup_processes_health_path, {} ],
    retry_sessions: [ :retry_sessions_health_path, {} ],
    archive_old: [ :archive_old_health_path, { days: 7 } ],
    enter_queue_recovery_mode: [ :enter_queue_recovery_mode_health_path, { reason: "test", ttl_minutes: 30 } ],
    run_post_deploy_tasks: [ :run_post_deploy_tasks_health_path, {} ]
  }.freeze

  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    AlertService.stubs(:raise_alert).returns(true)

    AppSetting.delete_all
    GoodJob::Setting.delete_all

    @original_password = ENV[PASSWORD_ENV]
    @original_username = ENV[USERNAME_ENV]
    ENV[PASSWORD_ENV] = PASSWORD
    ENV.delete(USERNAME_ENV)

    # The cooldown fails closed when the cache cannot enforce it, and the test env's
    # null_store cannot — which would answer 503 and mask the 401/200 this file is about.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ApplicationController.recovery_mode_reconciled_at = nil
  end

  teardown do
    Rails.cache.clear
    Rails.cache = @original_cache
    GoodJob::Setting.delete_all
    ApplicationController.recovery_mode_reconciled_at = nil
    restore_env(PASSWORD_ENV, @original_password)
    restore_env(USERNAME_ENV, @original_username)
  end

  # === Refused without the credential ===

  GATED.each do |action, (path_helper, params)|
    test "#{action} is refused without the operator credential" do
      post send(path_helper), params: params

      assert_response :unauthorized
      assert_match(/Basic realm=/, response.headers["WWW-Authenticate"].to_s)
    end

    test "#{action} is refused with a wrong password" do
      post send(path_helper), params: params, headers: basic_auth_headers("supervisor", "wrong")

      assert_response :unauthorized
    end

    test "#{action} is refused with a wrong username" do
      post send(path_helper), params: params, headers: basic_auth_headers("someone-else", PASSWORD)

      assert_response :unauthorized
    end

    test "#{action} is served with the operator credential" do
      post send(path_helper), params: params, headers: basic_auth_headers("supervisor", PASSWORD)

      assert_redirected_to health_dashboard_path
    end
  end

  # The failure this guards against is a new mutating action landing on the controller
  # without anybody remembering the gate — which would be invisible, because the action
  # would work exactly as its author expected.
  test "every mutating /health route is in the gated list or explicitly exempt" do
    exempt = %i[exit_queue_recovery_mode]

    posted_actions = Rails.application.routes.routes.filter_map do |route|
      next unless route.defaults[:controller] == "health"
      next unless route.verb == "POST"

      route.defaults[:action].to_sym
    end.uniq

    assert_equal (GATED.keys + exempt).sort, posted_actions.sort,
      "a POST route on HealthController is neither gated nor listed as a deliberate exemption"
    assert_equal GATED.keys.sort, HealthController::OPERATOR_GATED_ACTIONS.sort
  end

  # === Fails closed ===

  test "an unset password refuses even a correctly-formed credential" do
    ENV.delete(PASSWORD_ENV)

    post cleanup_processes_health_path, headers: basic_auth_headers("supervisor", PASSWORD)

    assert_response :unauthorized
  end

  test "a blank password refuses" do
    ENV[PASSWORD_ENV] = "   "

    post cleanup_processes_health_path, headers: basic_auth_headers("supervisor", "   ")

    assert_response :unauthorized
  end

  # An unconfigured realm refuses WITHOUT challenging, and says why in HTML. A challenge
  # there would open a browser dialog that no credential can satisfy, and its text/plain
  # body is a body Turbo will not render — between them, a button that does nothing.
  test "the refusal on an unconfigured realm explains itself instead of prompting" do
    ENV.delete(PASSWORD_ENV)

    post cleanup_processes_health_path

    assert_response :unauthorized
    assert_nil response.headers["WWW-Authenticate"]
    assert_equal "text/html", response.media_type
    assert_match PASSWORD_ENV, response.body
  end

  test "a configured realm does challenge, so the browser prompts and re-sends the POST" do
    post cleanup_processes_health_path

    assert_response :unauthorized
    assert_match(/Basic realm=/, response.headers["WWW-Authenticate"].to_s)
  end

  test "SUPERVISOR_USERNAME overrides the default username" do
    ENV[USERNAME_ENV] = "jon"

    post cleanup_processes_health_path, headers: basic_auth_headers("jon", PASSWORD)
    assert_redirected_to health_dashboard_path

    post cleanup_processes_health_path, headers: basic_auth_headers("supervisor", PASSWORD)
    assert_response :unauthorized
  end

  # === The Accept headers real callers send ===

  # The dashboard's controls are `button_to` / `form_with`, so every genuine browser refusal
  # arrives with Turbo's Accept list rather than the plain `text/html` the other tests send.
  # `turbo_stream` is not a registered mime here, so `respond_to` must fall through to the
  # html branch; if it ever stopped doing so the refusal would become a bodyless 406 via
  # ApplicationController#unknown_format — a silent failure, hence the assertion.
  TURBO_ACCEPT = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"

  test "a Turbo form submission is challenged, not answered with a 406" do
    post cleanup_processes_health_path, headers: { "Accept" => TURBO_ACCEPT }

    assert_response :unauthorized
    assert_match(/Basic realm=/, response.headers["WWW-Authenticate"].to_s)
  end

  test "a Turbo form submission against an unconfigured realm gets the explanation" do
    ENV.delete(PASSWORD_ENV)

    post cleanup_processes_health_path, headers: { "Accept" => TURBO_ACCEPT }

    assert_response :unauthorized
    assert_match PASSWORD_ENV, response.body
  end

  # === A JSON client gets a body, not a browser prompt ===

  test "a JSON refusal carries a message and no challenge header" do
    post cleanup_processes_health_path, headers: { "Accept" => "application/json" }

    assert_response :unauthorized
    assert_nil response.headers["WWW-Authenticate"]
    assert_equal "Unauthorized", JSON.parse(response.body)["error"]
  end

  # === What must stay open ===

  test "the read-only dashboard is still anonymous" do
    get health_dashboard_path

    assert_response :success
  end

  test "the other read-only surfaces are still anonymous" do
    get refresh_health_path
    assert_response :success

    get export_diagnostics_health_path, headers: { "Accept" => "application/json" }
    assert_response :success

    # The two the deploy's health gate hits. A 401 on either fails every cutover.
    get "/up"
    assert_response :success

    get deep_health_check_path
    assert_includes [ 200, 503 ], response.status
    refute_equal 401, response.status
  end

  test "exiting queue recovery mode stays open, because the way out of a halt must" do
    QueueRecoveryMode.enter!(reason: "test", actor: "test")
    assert QueueRecoveryMode.active?

    post exit_queue_recovery_mode_health_path

    assert_redirected_to health_dashboard_path
    refute QueueRecoveryMode.active?
  end

  test "an unconfigured realm still lets an operator out of a halt" do
    QueueRecoveryMode.enter!(reason: "test", actor: "test")
    ENV.delete(PASSWORD_ENV)

    post exit_queue_recovery_mode_health_path

    assert_redirected_to health_dashboard_path
    refute QueueRecoveryMode.active?
  end

  # The gate is on the web surface only. The REST sibling has always had its own
  # credential, and moving /health onto HTTP Basic must not have disturbed it.
  test "the REST sibling still answers to an API key and not to the operator credential" do
    original_keys = ENV["API_KEYS"]
    ENV["API_KEYS"] = "test_api_key_health_gate"

    post cleanup_processes_api_v1_health_path, headers: { "X-API-Key" => "test_api_key_health_gate" }
    assert_response :success

    post cleanup_processes_api_v1_health_path, headers: basic_auth_headers("supervisor", PASSWORD)
    assert_response :unauthorized
  ensure
    original_keys.nil? ? ENV.delete("API_KEYS") : ENV["API_KEYS"] = original_keys
  end

  private

  def basic_auth_headers(username, password)
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }
  end

  def restore_env(key, value)
    value.nil? ? ENV.delete(key) : ENV[key] = value
  end
end
