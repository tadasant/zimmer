# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The Inference page on the REST surface, for the iOS app. The read answers any
# key or grant with what the page renders — never a token or a key. Every write
# is an operator's lever over which account the fleet runs on and how much work
# it does, so it reaches only the app's token on a grant that acts as its
# approver: an API key is the fleet's, and a relay-only grant was approved to
# carry messages, not to decide.
class NativeAppInferenceTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  ISSUER = "http://www.example.com"
  RESOURCE = "#{ISSUER}/mcp".freeze
  CLIENT_ID = OauthServer::NativeApp::CLIENT_ID
  REDIRECT = OauthServer::NativeApp::REDIRECT_URI
  API_KEY = "test_api_key_native_inference"
  ENV_KEYS = %w[API_KEYS OAUTH_SERVER_ISSUER OAUTH_SERVER_ALLOWED_DOMAINS ZIMMER_DEV_WEB_USER_EMAIL].freeze

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV["API_KEYS"] = API_KEY
    ENV["OAUTH_SERVER_ISSUER"] = ISSUER
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "tadasant.com"
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "tadas@tadasant.com"

    # A switch probes the stored access token before admitting the account, and
    # activating a Claude account takes a quota snapshot — stub both so no test
    # reaches Anthropic.
    honoured = Net::HTTPSuccess.new("1.1", "200", "OK")
    honoured.stubs(:code).returns("200")
    honoured.stubs(:body).returns({ access_token: "stubbed-access-token", refresh_token: "stubbed-refresh-token", expires_in: 3600 }.to_json)
    Net::HTTP.any_instance.stubs(:request).returns(honoured)
    QuotaCheckService.stubs(:check_with_token).returns(quota_result(utilization_5h: 0.5, utilization_7d: 0.3))
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # ── the read ──────────────────────────────────────────────────────────

  test "a relay-only app and an API key both read the roster, the pool, the log and the policy" do
    AccountRotationEvent.create!(rotated_from: claude_accounts(:secondary), rotated_to: claude_accounts(:primary),
      reason: "manual_switch", source: "manual", triggered_by: "tadas@tadasant.com via the iOS app")

    [ bearer(token), { "X-API-Key" => API_KEY } ].each do |headers|
      get "/api/v1/inference", headers: headers
      assert_response :success, response.body
      body = JSON.parse(response.body)

      assert_equal "claude_code", body["runtime"]
      assert_equal %w[claude_code codex pi], body["runtimes"].map { |r| r["key"] }

      primary = body["accounts"].find { |a| a["email"] == "tadas@tadasant.com" }
      assert primary["is_current"]
      assert_equal "active", primary["effective_status"]
      assert_equal "unverified", primary["credentials"]["state"], "stored, and never checked against Anthropic"
      assert_in_delta 0.45, primary["quota"]["five_hour"]["utilization"]
      assert_equal "allowed", primary["quota"]["five_hour"]["status"]
      assert primary["quota"]["five_hour"]["reset_at"].present?
      assert primary["login"]["available"]
      assert_nil primary["login"]["active_attempt"]

      unconfigured = body["accounts"].find { |a| a["email"] == "unconfigured@example.com" }
      assert_equal "none", unconfigured["credentials"]["state"]
      assert_nil unconfigured["quota"]

      assert_equal body["accounts"].size, body["pool"]["total"]
      assert body["pool"].key?("five_hour_utilization")

      event = body["rotation_log"].first
      assert_equal "sam@tadasant.com", event["from"]["email"]
      assert_equal "tadas@tadasant.com", event["to"]["email"]
      assert_equal "tadas@tadasant.com via the iOS app", event["triggered_by"]

      policy = body["spot_policy"]
      assert_includes [ true, false ], policy["gating_enabled"]
      assert policy["decision"].key?("allowed")
      assert_equal %w[max_running_sessions idle_minutes min_fire_interval_minutes quiet_backlog_interval_minutes],
        body["fleet_top_up"].keys.first(4)
      web_ui = body["genesis_classes"]["kinds"].find { |k| k["key"] == "web_ui" }
      assert_equal "priority", web_ui["class"]
      assert web_ui["settable"]
      refute body["genesis_classes"]["kinds"].find { |k| k["key"] == "slack" }["settable"]

      assert_nil body["openrouter_key"], "the key card is the Pi tab's"
      assert_no_match(/test_access_token|test_refresh_token|oauth_config/, response.body, "no credential leaves the roster")
    end
  end

  test "the Codex tab lists Codex accounts without quota windows" do
    get "/api/v1/inference", params: { runtime: "codex" }, headers: bearer(token)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "codex", body["runtime"]
    api_key_account = body["accounts"].find { |a| a["api_key_account"] }
    assert api_key_account, "the Codex pool carries its API-key account"
    assert body["accounts"].all? { |a| a["quota"].nil? }
    assert_no_match(/codex_access_token|codex_refresh_token|OPENAI_API_KEY/, response.body)
  end

  test "the read converges a quota_exceeded column whose windows have cleared, as the page does" do
    account = claude_accounts(:exceeded)
    account.quota_snapshots.delete_all
    account.quota_snapshots.create!(utilization_5h: 0.1, utilization_7d: 0.1, status_5h: "allowed", status_7d: "allowed",
      reset_5h: 2.hours.from_now, reset_7d: 3.days.from_now, trigger: "page_view")

    get "/api/v1/inference", headers: { "X-API-Key" => API_KEY }

    assert_response :success
    assert account.reload.active?
  end

  # ── the fence on every write ─────────────────────────────────────────

  test "every write is refused over an API key and over a relay-only grant, and changes nothing" do
    account = claude_accounts(:secondary)
    attempt = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_code")
    writes = [
      [ :post, "/api/v1/inference/accounts", { runtime: "claude_code", email: "new@tadasant.com" } ],
      [ :post, "/api/v1/inference/accounts/#{account.id}/refresh", {} ],
      [ :post, "/api/v1/inference/accounts/#{account.id}/activate", {} ],
      [ :delete, "/api/v1/inference/accounts/#{account.id}", {} ],
      [ :post, "/api/v1/inference/logins", { account_id: account.id } ],
      [ :post, "/api/v1/inference/logins/#{attempt.id}/code", { code: "abc" } ],
      [ :post, "/api/v1/inference/logins/#{attempt.id}/cancel", {} ],
      [ :patch, "/api/v1/inference/spot_policy", { enabled: true } ],
      [ :patch, "/api/v1/inference/fleet_top_up", { idle_minutes: 9 } ],
      [ :patch, "/api/v1/inference/genesis/web_ui", { priority_class: "spot" } ],
      [ :delete, "/api/v1/inference/genesis", {} ]
    ]

    writes.each do |verb, path, params|
      send(verb, path, params: params, headers: { "X-API-Key" => API_KEY })
      assert_response :forbidden, "#{verb.upcase} #{path} over a key: #{response.body}"
      assert_match(/Only a person/, JSON.parse(response.body)["message"])

      send(verb, path, params: params, headers: bearer(token))
      assert_response :forbidden, "#{verb.upcase} #{path} on a relay-only grant: #{response.body}"
      assert_match(/may not act as you/, JSON.parse(response.body)["message"])
    end

    assert ClaudeAccount.exists?(account.id)
    assert claude_accounts(:primary).reload.is_current?
    assert_equal "awaiting_code", attempt.reload.status
    assert_nil attempt.pasted_code
    assert_equal 0, RuntimeLoginAttempt.where.not(id: attempt.id).count
    refute ClaudeAccount.exists?(email: "new@tadasant.com")
    assert_nil AppSetting.order(:id).first&.genesis_class_overrides&.fetch("web_ui", nil)
  end

  # ── the account verbs, acting as you ─────────────────────────────────

  test "refresh probes the account and answers its fresh reading" do
    account = claude_accounts(:secondary)
    QuotaCheckService.expects(:check_with_token).with("test_access_token_2").returns(quota_result(utilization_5h: 0.62, utilization_7d: 0.4))

    assert_difference -> { account.quota_snapshots.count }, 1 do
      post "/api/v1/inference/accounts/#{account.id}/refresh", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    end

    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_in_delta 0.62, body["account"]["quota"]["five_hour"]["utilization"]
    assert_equal "manual_refresh", body["account"]["quota"]["trigger"]
    assert_nil body["account"]["probe_error"]
    assert body["pool"].key?("servable_count")
  end

  test "a failed probe answers the last reading and says the probe failed" do
    account = claude_accounts(:secondary)
    QuotaCheckService.stubs(:check_with_token).returns(QuotaCheckService::Result.new(success: false, error_message: "HTTP 503 from Anthropic"))

    post "/api/v1/inference/accounts/#{account.id}/refresh", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_equal "HTTP 503 from Anthropic", body["account"]["probe_error"]
    assert_in_delta 0.70, body["account"]["quota"]["five_hour"]["utilization"], 0.001, "the reading on file stays"
  end

  test "activate switches the current account and names you on the rotation event" do
    account = claude_accounts(:secondary)

    post "/api/v1/inference/accounts/#{account.id}/activate", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert body["account"]["is_current"]
    assert_equal "Switched to sam@tadasant.com", body["message"]
    assert account.reload.is_current?
    refute claude_accounts(:primary).reload.is_current?
    event = AccountRotationEvent.order(:id).last
    assert_equal "manual_switch", event.reason
    assert_equal "manual", event.source
    assert_equal "tadas@tadasant.com via the iOS app", event.triggered_by
  end

  test "activate refuses an account with no credentials, as the page does" do
    account = claude_accounts(:unconfigured)

    post "/api/v1/inference/accounts/#{account.id}/activate", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    assert_response :unprocessable_entity
    assert_match(/no credentials stored/, JSON.parse(response.body)["message"])
    assert claude_accounts(:primary).reload.is_current?
  end

  test "delete removes the account; deleting the current one hands over and records who did it" do
    secondary = claude_accounts(:secondary)
    delete "/api/v1/inference/accounts/#{secondary.id}", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    assert_response :success, response.body
    refute ClaudeAccount.exists?(secondary.id)
    assert_equal "tadas@tadasant.com", JSON.parse(response.body)["current_account"]["email"]

    primary = claude_accounts(:primary)
    delete "/api/v1/inference/accounts/#{primary.id}", headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    assert_response :success, response.body
    body = JSON.parse(response.body)
    refute ClaudeAccount.exists?(primary.id)
    assert body["current_account"], "the next activatable account takes over"
    assert body["current_account"]["is_current"]
    event = AccountRotationEvent.order(:id).last
    assert_equal "deleted_current_account", event.reason
    assert_equal "tadas@tadasant.com", event.rotated_from_email
    assert_equal "tadas@tadasant.com via the iOS app", event.triggered_by
  end

  test "adding an account creates an unauthenticated row, and refuses a duplicate or a blank email" do
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    post "/api/v1/inference/accounts", params: { runtime: "claude_code", email: "new@tadasant.com", priority: 7 }, headers: headers
    assert_response :created, response.body
    body = JSON.parse(response.body)
    assert_equal "needs_reauth", body["account"]["status"]
    assert_equal 7, body["account"]["priority"]
    assert_match(/Authenticate it/, body["message"])

    post "/api/v1/inference/accounts", params: { runtime: "claude_code", email: "new@tadasant.com" }, headers: headers
    assert_response :unprocessable_entity
    assert_match(/already exists/, JSON.parse(response.body)["message"])

    post "/api/v1/inference/accounts", params: { runtime: "claude_code", email: " " }, headers: headers
    assert_response :unprocessable_entity
    assert_match(/Email is required/, JSON.parse(response.body)["message"])
  end

  # ── the CLI login flow ───────────────────────────────────────────────

  test "a login is started, polled, given its code and canceled from the app" do
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    account = claude_accounts(:unconfigured)
    stale = account.runtime_login_attempts.create!(runtime: account.runtime, status: "awaiting_user")
    RuntimeLoginJob.expects(:perform_later).once

    post "/api/v1/inference/logins", params: { account_id: account.id }, headers: headers
    assert_response :created, response.body
    login = JSON.parse(response.body)["login"]
    assert_equal "starting", login["status"]
    assert_equal "canceled", stale.reload.status, "the prior live attempt is superseded"
    attempt = RuntimeLoginAttempt.find(login["id"])

    # The worker surfaces the link; the poll carries it, and the account beside it.
    attempt.update!(status: "awaiting_code", verification_url: "https://claude.ai/oauth/authorize?x=1", heartbeat_at: Time.current)
    get "/api/v1/inference/logins/#{attempt.id}", headers: bearer(token)
    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_equal "https://claude.ai/oauth/authorize?x=1", body["login"]["verification_url"]
    assert body["login"]["awaiting_code"]
    refute body["login"]["code_received"]
    assert_equal account.id, body["account"]["id"]

    post "/api/v1/inference/logins/#{attempt.id}/code", params: { code: "pasted-code" }, headers: headers
    assert_response :success, response.body
    assert JSON.parse(response.body)["login"]["code_received"]
    assert_equal "pasted-code", attempt.reload.pasted_code
    assert_no_match(/pasted-code/, response.body, "the code is consumed by the worker, never echoed")

    post "/api/v1/inference/logins/#{attempt.id}/cancel", headers: headers
    assert_response :success, response.body
    assert_equal "canceled", attempt.reload.status
    assert_nil attempt.pasted_code
  end

  test "a login for an API-key account is refused, and a pruned attempt is a 404" do
    RuntimeLoginJob.expects(:perform_later).never

    post "/api/v1/inference/logins", params: { account_id: claude_accounts(:codex_api_key).id },
      headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    assert_response :unprocessable_entity
    assert_match(/don't use the login flow/, JSON.parse(response.body)["message"])

    get "/api/v1/inference/logins/0", headers: bearer(token)
    assert_response :not_found
    assert_match(/no longer tracked/, JSON.parse(response.body)["message"])
  end

  # ── the policy writes, with the tool's validation ────────────────────

  test "the spot policy is written with the tool's parameters and the audit line names you" do
    AppSetting.delete_all
    AppSetting.editable.update!(spot_gating_enabled: false, spot_reserve_five_hour_pct: 20)

    entries = capture_log_entries do
      patch "/api/v1/inference/spot_policy",
        params: { enabled: true, five_hour_reserve_pct: 35, preemption_enabled: false, starvation_age_ceiling_hours: 0 },
        headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    end

    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_equal %w[enabled five_hour_reserve_pct preemption_enabled starvation_age_ceiling_hours], body["changed"]
    assert body["spot_policy"]["gating_enabled"]
    assert_equal 35, body["spot_policy"]["five_hour_reserve_pct"]
    refute body["spot_policy"]["preemption_enabled"]
    setting = AppSetting.current
    assert setting.spot_gating_enabled
    assert_equal 35, setting.spot_reserve_five_hour_pct
    assert_equal 0, setting.spot_starvation_age_ceiling_hours
    audit = entries.map(&:last).find { |m| m.include?("[FleetPolicy]") }
    assert audit, "the policy change is recorded"
    assert_match(/tadas@tadasant.com via the iOS app/, audit)
    assert_match(/spot_reserve_five_hour_pct 20 -> 35/, audit)
  end

  test "the spot policy refuses an empty write and an out-of-range reserve without persisting it" do
    AppSetting.delete_all
    AppSetting.editable.update!(spot_reserve_five_hour_pct: 80)
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    patch "/api/v1/inference/spot_policy", params: {}, headers: headers
    assert_response :unprocessable_entity
    assert_equal "Nothing to change", JSON.parse(response.body)["error"]

    patch "/api/v1/inference/spot_policy", params: { five_hour_reserve_pct: 140 }, headers: headers
    assert_response :unprocessable_entity
    assert_equal "Invalid spot policy", JSON.parse(response.body)["error"]
    assert_equal 80, AppSetting.current.spot_reserve_five_hour_pct
  end

  test "the top-up policy is written and refuses a ceiling of zero" do
    AppSetting.delete_all
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    patch "/api/v1/inference/fleet_top_up", params: { max_running_sessions: 4, idle_minutes: 12 }, headers: headers
    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_equal 4, body["fleet_top_up"]["max_running_sessions"]
    assert_equal 12, body["fleet_top_up"]["idle_minutes"]
    assert body["fleet_top_up"]["sentence"].present?

    patch "/api/v1/inference/fleet_top_up", params: { max_running_sessions: 0 }, headers: headers
    assert_response :unprocessable_entity
    assert_equal "Invalid top-up policy", JSON.parse(response.body)["error"]
    assert_equal 4, AppSetting.current.fleet_idle_max_sessions

    patch "/api/v1/inference/fleet_top_up", params: {}, headers: headers
    assert_response :unprocessable_entity
    assert_equal "Nothing to change", JSON.parse(response.body)["error"]
  end

  test "a genesis kind is reclassified, refused when a trigger owns it, and reset" do
    AppSetting.delete_all
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))

    patch "/api/v1/inference/genesis/web_ui", params: { priority_class: "spot" }, headers: headers
    assert_response :success, response.body
    body = JSON.parse(response.body)
    assert_match(/Zimmer web app is now spot/, body["message"])
    web_ui = body["genesis_classes"]["kinds"].find { |k| k["key"] == "web_ui" }
    assert_equal "spot", web_ui["class"]
    assert web_ui["overridden"]
    assert_equal({ "web_ui" => "spot" }, AppSetting.current.genesis_class_overrides)

    patch "/api/v1/inference/genesis/slack", params: { priority_class: "spot" }, headers: headers
    assert_response :unprocessable_entity
    assert_match(/from the trigger that fires it/, JSON.parse(response.body)["message"])

    patch "/api/v1/inference/genesis/nope", params: { priority_class: "spot" }, headers: headers
    assert_response :unprocessable_entity
    assert_equal "Unknown genesis", JSON.parse(response.body)["error"]

    patch "/api/v1/inference/genesis/web_ui", params: { priority_class: "urgent" }, headers: headers
    assert_response :unprocessable_entity
    assert_equal "Unknown class", JSON.parse(response.body)["error"]

    delete "/api/v1/inference/genesis", headers: headers
    assert_response :success, response.body
    assert_equal({}, AppSetting.current.genesis_class_overrides)
    assert_equal "priority", JSON.parse(response.body)["genesis_classes"]["kinds"].find { |k| k["key"] == "web_ui" }["class"]
  end

  private

  def pkce
    verifier = SecureRandom.urlsafe_base64(48)
    [ verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) ]
  end

  def token(privilege: OauthServer::RELAY_ONLY)
    verifier, challenge = pkce
    post "/oauth/authorize", params: { response_type: "code", client_id: CLIENT_ID, redirect_uri: REDIRECT,
      code_challenge: challenge, code_challenge_method: "S256", state: "s1", resource: RESOURCE, scope: "mcp",
      decision: "approve", privilege: privilege }
    assert_response :found
    code = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("code")
    post "/oauth/token", params: { grant_type: "authorization_code", client_id: CLIENT_ID, code: code,
      code_verifier: verifier, redirect_uri: REDIRECT, resource: RESOURCE }
    assert_response :success
    JSON.parse(response.body).fetch("access_token")
  end

  def bearer(access_token) = { "Authorization" => "Bearer #{access_token}" }

  def quota_result(utilization_5h:, utilization_7d:)
    QuotaCheckService::Result.new(
      success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
      utilization_5h: utilization_5h, utilization_7d: utilization_7d,
      status_5h: "allowed", status_7d: "allowed",
      reset_5h: 3.hours.from_now, reset_7d: 5.days.from_now
    )
  end
end
