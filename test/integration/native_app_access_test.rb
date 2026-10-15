# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct"

# What the iOS app's token reaches beyond the sessions controller, action by
# action (`accepts_native_app_tokens only:`). Each controller the app reads or
# drives is open for exactly those actions; every other action on it answers the
# app's token with the same 401 a bad key gets.
class NativeAppAccessTest < ActionDispatch::IntegrationTest
  include WebAuthTestHelpers

  ISSUER = "http://www.example.com"
  RESOURCE = "#{ISSUER}/mcp".freeze
  CLIENT_ID = OauthServer::NativeApp::CLIENT_ID
  REDIRECT = OauthServer::NativeApp::REDIRECT_URI
  API_KEY = "test_api_key_native_access"
  ENV_KEYS = %w[API_KEYS OAUTH_SERVER_ISSUER OAUTH_SERVER_ALLOWED_DOMAINS ZIMMER_DEV_WEB_USER_EMAIL].freeze

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV["API_KEYS"] = API_KEY
    ENV["OAUTH_SERVER_ISSUER"] = ISSUER
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "tadasant.com"
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "tadas@tadasant.com"
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "a read-only controller answers the app's reads and refuses its writes" do
    headers = bearer(token)
    session = build_zimmer_session(status: :needs_input)
    log = session.logs.create!(content: "Cloned the repo", level: "info")

    get "/api/v1/sessions/#{session.id}/logs", headers: headers
    assert_response :success
    get "/api/v1/sessions/#{session.id}/logs/#{log.id}", headers: headers
    assert_response :success

    post "/api/v1/sessions/#{session.id}/logs", params: { log: { content: "forged", level: "info" } }, headers: headers
    assert_response :unauthorized
    delete "/api/v1/sessions/#{session.id}/logs/#{log.id}", headers: headers
    assert_response :unauthorized
    assert_equal [ "Cloned the repo" ], session.logs.pluck(:content)
  end

  test "logs can leave the verbose level out, as the web UI's Show Logs does" do
    session = build_zimmer_session(status: :running)
    session.logs.create!(content: "Cloned the repo", level: "info")
    session.logs.create!(content: "raw cli output", level: Log::VERBOSE_LEVEL)

    get "/api/v1/sessions/#{session.id}/logs", params: { exclude_level: Log::VERBOSE_LEVEL }, headers: bearer(token)

    assert_response :success
    assert_equal [ "Cloned the repo" ], JSON.parse(response.body)["logs"].map { |l| l["content"] }
  end

  test "the app reads and manages a session's queue but adds to it only through follow_up" do
    headers = bearer(token)
    session = build_zimmer_session(status: :running)
    first = session.enqueued_messages.create!(content: "first", position: 1, status: "pending")
    second = session.enqueued_messages.create!(content: "second", position: 2, status: "pending")

    get "/api/v1/sessions/#{session.id}/enqueued_messages", headers: headers
    assert_response :success

    patch "/api/v1/sessions/#{session.id}/enqueued_messages/#{second.id}/reorder", params: { position: 1 }, headers: headers
    assert_response :success

    delete "/api/v1/sessions/#{session.id}/enqueued_messages/#{first.id}", headers: headers
    assert_response :success
    assert_not EnqueuedMessage.exists?(first.id)

    post "/api/v1/sessions/#{session.id}/enqueued_messages", params: { content: "sneaked in" }, headers: headers
    assert_response :unauthorized
  end

  test "editing a queued message from an app that acts on its approver's behalf records it as theirs" do
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    session = build_zimmer_session(status: :running)
    queued = session.enqueued_messages.create!(content: "deploy", position: 1, status: "pending")
    from_key = session.enqueued_messages.create!(content: "other", position: 2, status: "pending")

    patch "/api/v1/sessions/#{session.id}/enqueued_messages/#{queued.id}", params: { content: "deploy to staging only" }, headers: headers
    assert_response :success
    patch "/api/v1/sessions/#{session.id}/enqueued_messages/#{from_key.id}", params: { content: "from a script" }, headers: { "X-API-Key" => API_KEY }
    assert_response :success

    message = session.human_messages.sole
    assert_equal "deploy to staging only", message.content
    assert_equal HumanMessage::ASSISTANT, message.channel
    assert_equal "ios_app.enqueued_message_edited", message.provenance["entry_point"]
  end

  test "a session started from an app that acts on its approver's behalf records its prompt as theirs" do
    AgentSessionJob.stubs(:enqueue_new_session).returns(OpenStruct.new(job_id: "job-1"))

    post "/api/v1/sessions", params: { agent_root: "zimmer", prompt: "Rotate the staging deploy key" },
      headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    assert_response :created
    from_phone = Session.find(JSON.parse(response.body)["session"]["id"])

    post "/api/v1/sessions", params: { agent_root: "zimmer", prompt: "From a script" }, headers: { "X-API-Key" => API_KEY }
    assert_response :created
    from_key = Session.find(JSON.parse(response.body)["session"]["id"])

    message = from_phone.human_messages.sole
    assert_equal "Rotate the staging deploy key", message.content
    assert_equal "ios_app.new_session", message.provenance["entry_point"]
    assert_empty from_key.human_messages
  end

  test "a relay-only app's edit records nothing" do
    session = build_zimmer_session(status: :running)
    queued = session.enqueued_messages.create!(content: "deploy", position: 1, status: "pending")

    patch "/api/v1/sessions/#{session.id}/enqueued_messages/#{queued.id}", params: { content: "changed" }, headers: bearer(token)

    assert_response :success
    assert_empty session.human_messages
  end

  test "notifications, triggers, costs, health and the catalogs answer the app's reads" do
    headers = bearer(token)

    [ "/api/v1/notifications", "/api/v1/notifications/badge", "/api/v1/triggers", "/api/v1/costs",
      "/api/v1/health", "/api/v1/configs", "/api/v1/mcp_servers", "/api/v1/skills", "/api/v1/hooks", "/api/v1/plugins",
      "/api/v1/model_catalog_entries" ].each do |path|
      get path, headers: headers
      assert_response :success, "#{path} did not answer the app's token"
    end
  end

  test "each controller's operator and authoring actions stay closed to the app" do
    headers = bearer(token)
    # The token is refused before the record is looked up, so no trigger needs to exist:
    # a 401 here, rather than the 404 an API key would get, is the boundary.

    post "/api/v1/notifications/push", params: { title: "t", body: "b" }, headers: headers
    assert_response :unauthorized
    delete "/api/v1/triggers/0", headers: headers
    assert_response :unauthorized
    post "/api/v1/triggers", params: { name: "x" }, headers: headers
    assert_response :unauthorized
    post "/api/v1/health/enter_queue_recovery_mode", headers: headers
    assert_response :unauthorized
    post "/api/v1/costs/backfill", headers: headers
    assert_response :unauthorized
    post "/api/v1/model_catalog_entries", params: { runtime: "claude_code", model: "x" }, headers: headers
    assert_response :unauthorized
  end

  test "the hook and plugin catalogs answer an API key with the catalog's entries" do
    get "/api/v1/hooks", headers: { "X-API-Key" => API_KEY }
    assert_response :success
    assert_equal HooksConfig.all.map(&:id), JSON.parse(response.body)["hooks"].map { |h| h["id"] }

    get "/api/v1/plugins", headers: { "X-API-Key" => API_KEY }
    assert_response :success
    assert_equal PluginsConfig.all.map(&:id), JSON.parse(response.body)["plugins"].map { |p| p["id"] }
  end

  test "the app lists a session's open prompts and answers one when it acts on its approver's behalf" do
    headers = bearer(token(privilege: OauthServer::ACT_AS_HUMAN))
    session = build_zimmer_session(status: :needs_input)
    open_prompt = create_elicitation(session, message: "Send the email?")
    too_late = create_elicitation(session, message: "Too late", expires_at: 1.minute.ago)
    create_elicitation(session, message: "Answered").update!(status: "accept", responded_at: Time.current)

    get "/api/v1/sessions/#{session.id}/elicitations", headers: headers
    assert_response :success
    listed = JSON.parse(response.body)["elicitations"]
    assert_equal [ open_prompt.id ], listed.map { |e| e["id"] }, "only the prompt that can still be answered"
    assert_equal "pending", too_late.reload.status, "a read leaves expiry to the sweep"
    assert_equal %w[to confirmed], listed.first["field_order"]
    assert_equal "boolean", listed.first.dig("requested_schema", "properties", "confirmed", "type")

    patch "/api/v1/elicitations/#{open_prompt.id}/respond", params: { action_type: "accept", content: { confirmed: true } },
      headers: headers, as: :json
    assert_response :success
    assert_equal "accept", open_prompt.reload.status
    assert_equal({ "confirmed" => true }, open_prompt.response_content)
  end

  test "a relay-only app reads a prompt but may not answer it, and never raises or polls one" do
    headers = bearer(token)
    session = build_zimmer_session(status: :needs_input)
    prompt = create_elicitation(session, message: "Send the email?")

    get "/api/v1/sessions/#{session.id}/elicitations", headers: headers
    assert_response :success

    patch "/api/v1/elicitations/#{prompt.id}/respond", params: { action_type: "accept" }, headers: headers
    assert_response :forbidden
    assert_equal "pending", prompt.reload.status

    patch "/api/v1/elicitations/0/respond", params: { action_type: "accept" }, headers: headers
    assert_response :forbidden, "refused before the lookup, so it cannot tell which ids exist"

    get "/api/v1/elicitations/#{prompt.request_id}", headers: headers
    assert_response :unauthorized
    post "/api/v1/elicitations", params: { message: "forged", _meta: { "com.pulsemcp/request-id" => "r" } }, headers: headers
    assert_response :unauthorized
  end

  test "a session's open prompts answer an API key too, and an unknown session is a 404" do
    session = build_zimmer_session(status: :needs_input)
    prompt = create_elicitation(session, message: "Send the email?")

    get "/api/v1/sessions/#{session.id}/elicitations", headers: { "X-API-Key" => API_KEY }
    assert_response :success
    assert_equal [ prompt.id ], JSON.parse(response.body)["elicitations"].map { |e| e["id"] }

    get "/api/v1/sessions/0/elicitations", headers: { "X-API-Key" => API_KEY }
    assert_response :not_found
  end

  test "a controller the app does not use refuses its token outright" do
    get "/api/v1/gate_decisions", headers: bearer(token)
    assert_response :unauthorized
  end

  private

  def pkce
    verifier = SecureRandom.urlsafe_base64(48)
    [ verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) ]
  end

  # The Settings page's row over REST: the app reads it on any grant, writes the
  # session defaults and the experimental toggles on any grant (an agent may too,
  # through action_app_settings), and changes MCP Apps only acting as you.
  test "the app reads the settings and writes the defaults and experimental toggles" do
    headers = bearer(token)
    get "/api/v1/app_settings", headers: headers
    assert_response :success
    body = JSON.parse(response.body).fetch("app_settings")
    assert_equal RuntimeRegistry::DEFAULT_RUNTIME, body.dig("session_defaults", "runtime")
    assert_equal false, body.dig("session_defaults", "runtime_overridden")
    assert body["runtimes"].any? { |r| r["id"] == "claude_code" && r["models"].any? }
    first = ExperimentalSettingsRegistry.all.first
    entry = body["experimental"].find { |e| e["key"] == first.key }
    assert_equal first.current_value, entry["enabled"]
    assert_equal ExperimentalSettingsRegistry.default_on?(first), entry["default_enabled"]
    assert_equal false, body.dig("mcp_apps", "enabled")
    assert_kind_of Array, body.dig("mcp_apps", "eligible_servers")

    model = ModelCatalog.model_ids_for("claude_code").last
    patch "/api/v1/app_settings", params: { app_settings: { default_runtime: "claude_code", default_model: model } },
      headers: headers, as: :json
    assert_response :success
    assert_equal model, JSON.parse(response.body).dig("app_settings", "session_defaults", "model")
    assert_equal true, JSON.parse(response.body).dig("app_settings", "session_defaults", "model_overridden")
    assert_equal model, AppSetting.current.default_model

    was = first.current_value
    patch "/api/v1/app_settings", params: { app_settings: { experimental: { first.key => !was } } },
      headers: headers, as: :json
    assert_response :success
    assert_equal !was, first.current_value
    entry = JSON.parse(response.body).fetch("app_settings")["experimental"].find { |e| e["key"] == first.key }
    assert_equal first.current_value, entry["enabled"]
  end

  test "a bad runtime and model pair, or an unknown experimental key, is a 422 and changes nothing" do
    headers = bearer(token)
    patch "/api/v1/app_settings", params: { app_settings: { default_runtime: "claude_code", default_model: "not-a-model" } },
      headers: headers, as: :json
    assert_response :unprocessable_entity
    assert_nil AppSetting.current.default_model

    first = ExperimentalSettingsRegistry.all.first
    before = first.current_value
    patch "/api/v1/app_settings", params: { app_settings: { experimental: { "no_such_setting" => true, first.key => !before } } },
      headers: headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "Unknown experimental setting", JSON.parse(response.body)["error"]
    assert_equal before, first.current_value
  end

  test "MCP Apps change only on a grant that acts as you, never over an API key" do
    patch "/api/v1/app_settings", params: { app_settings: { mcp_apps_enabled: true } },
      headers: bearer(token), as: :json
    assert_response :forbidden
    assert_match(/sign in again/, JSON.parse(response.body)["message"])
    assert_equal false, AppSetting.current.mcp_apps_enabled?

    patch "/api/v1/app_settings", params: { app_settings: { mcp_apps_allowed_servers: [ "anything" ] } },
      headers: { "X-API-Key" => API_KEY }, as: :json
    assert_response :forbidden
    assert_match(/Only a person/, JSON.parse(response.body)["message"])

    patch "/api/v1/app_settings", params: { app_settings: { mcp_apps_enabled: true, mcp_apps_allowed_servers: [ "not-in-the-catalog" ] } },
      headers: bearer(token(privilege: OauthServer::ACT_AS_HUMAN)), as: :json
    assert_response :success
    body = JSON.parse(response.body).fetch("app_settings")
    assert_equal true, body.dig("mcp_apps", "enabled")
    assert_equal [], body.dig("mcp_apps", "allowed_servers"), "a server the catalog does not offer is dropped, as the page drops it"
    assert_equal true, AppSetting.current.mcp_apps_enabled?
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

  def create_elicitation(session, message:, expires_at: 10.minutes.from_now)
    Elicitation.create!(session: session, request_id: "req-#{SecureRandom.hex(6)}", mode: "form", message: message,
      requested_schema: { type: "object", properties: { to: { type: "string" }, confirmed: { type: "boolean" } } },
      expires_at: expires_at)
  end

  def build_zimmer_session(**attrs)
    Session.create!({ git_root: "https://github.com/tadasant/zimmer.git", branch: "main", prompt: "p" }.merge(attrs))
  end
end
