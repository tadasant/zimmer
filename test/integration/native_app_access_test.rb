# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

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
      "/api/v1/health", "/api/v1/configs", "/api/v1/mcp_servers", "/api/v1/skills",
      "/api/v1/model_catalog_entries" ].each do |path|
      get path, headers: headers
      assert_not_equal 401, response.status, "#{path} refused the app's token"
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

  test "a controller the app does not use refuses its token outright" do
    get "/api/v1/gate_decisions", headers: bearer(token)
    assert_response :unauthorized
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

  def build_zimmer_session(**attrs)
    Session.create!({ git_root: "https://github.com/tadasant/zimmer.git", branch: "main", prompt: "p" }.merge(attrs))
  end
end
