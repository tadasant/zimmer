# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Reads take an API key; starting, steering and speaking for a conversation take
# the iOS app's sign-in acting as its person (`@headers` below), because a live
# model reaches the whole catalog.
class Api::V1::LiveConversationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include WebAuthTestHelpers

  ISSUER = "http://www.example.com"
  ENV_KEYS = [ ApiKey::ENV_VAR, "OAUTH_SERVER_ISSUER", "OAUTH_SERVER_ALLOWED_DOMAINS", "ZIMMER_DEV_WEB_USER_EMAIL" ].freeze

  setup do
    @saved_env = ENV_KEYS.index_with { |k| ENV[k] }
    ENV[ApiKey::ENV_VAR] = "live-api-test-key"
    ENV["OAUTH_SERVER_ISSUER"] = ISSUER
    ENV["OAUTH_SERVER_ALLOWED_DOMAINS"] = "tadasant.com"
    ENV["ZIMMER_DEV_WEB_USER_EMAIL"] = "tadas@tadasant.com"
    WebAuth::Configuration.stubs(:current).returns(web_auth_configuration_with(client_id: nil, allowed_domains: nil))
    @key_headers = { "X-API-Key" => "live-api-test-key" }
    @headers = bearer(app_token(privilege: OauthServer::ACT_AS_HUMAN))
    stub_live_root
    stub_live_key
  end

  teardown do
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  test "an API key reads but cannot start, steer or speak for a conversation; nor can a relay-only sign-in" do
    stub_clock_server
    conversation = create_live_conversation(mode: "voice")
    get "/api/v1/live_conversations/#{conversation.id}", headers: @key_headers
    assert_response :success

    relay_only = bearer(app_token(privilege: OauthServer::RELAY_ONLY))
    writes = [
      [ "/api/v1/live_conversations", { mode: "text" } ],
      [ "/api/v1/live_conversations/#{conversation.id}/messages", { content: "hi" } ],
      [ "/api/v1/live_conversations/#{conversation.id}/mode", { mode: "text" } ],
      [ "/api/v1/live_conversations/#{conversation.id}/client_secret", {} ],
      [ "/api/v1/live_conversations/#{conversation.id}/tool_calls", { name: "enable_mcp_server", arguments: { name: "test-clock" }.to_json, call_id: "c" } ],
      [ "/api/v1/live_conversations/#{conversation.id}/turns", { role: "user", content: "hi" } ],
      [ "/api/v1/live_conversations/#{conversation.id}/finish", {} ]
    ]
    writes.each do |path, params|
      post path, params: params, headers: @key_headers
      assert_response :forbidden, "#{path} with an API key"
      assert_match(/Only a person/, response.parsed_body["message"])

      post path, params: params, headers: relay_only
      assert_response :forbidden, "#{path} with a relay-only sign-in"
      assert_match(/may not act as you/, response.parsed_body["message"])
    end
    assert_equal [ "zimmer" ], conversation.reload.mcp_servers, "nothing was enabled"
    assert conversation.active?
    assert conversation.voice?, "nothing switched it"
  end

  test "requires a credential" do
    get "/api/v1/live"
    assert_response :unauthorized
  end

  test "live reports one availability, and each mode's model, and why not" do
    get "/api/v1/live", headers: @key_headers
    assert_response :success
    assert response.parsed_body["available"]
    assert_equal "live-mode", response.parsed_body["agent_root"]
    modes = response.parsed_body["modes"].index_by { |m| m["mode"] }
    assert_equal "gpt-realtime-2.1-mini", modes["voice"]["model"]
    assert modes["voice"]["available"]

    stub_live_root(root: nil)
    get "/api/v1/live", headers: @key_headers
    assert_not response.parsed_body["available"]
    assert_match(/live-mode/, response.parsed_body["reasons"].first)
    assert(response.parsed_body["modes"].none? { |m| m["available"] })
  end

  test "start, message, read the thread, and end" do
    assert_enqueued_with(job: LiveConversationPrepareJob) do
      post "/api/v1/live_conversations", headers: @headers
    end
    assert_response :created
    id = response.parsed_body["id"]
    assert_equal "preparing", response.parsed_body["status"]
    assert_equal "text", response.parsed_body["mode"], "typed unless asked for voice"

    # Typed while preparing: accepted, answered once active.
    post "/api/v1/live_conversations/#{id}/messages", params: { content: "hello" }, headers: @headers
    assert_response :created
    first_turn = response.parsed_body["id"]

    get "/api/v1/live_conversations", headers: @headers
    assert_equal id, response.parsed_body["current_id"]
    assert_equal({ "text" => id }, response.parsed_body["current"])

    LiveConversation.find(id).turns.create!(role: "assistant", content: "Hi.")
    get "/api/v1/live_conversations/#{id}", params: { after_turn_id: first_turn }, headers: @headers
    assert_equal [ "Hi." ], response.parsed_body["turns"].map { |t| t["content"] }

    post "/api/v1/live_conversations/#{id}/finish", headers: @headers
    assert_equal "ended", response.parsed_body["status"]

    post "/api/v1/live_conversations/#{id}/messages", params: { content: "again" }, headers: @headers
    assert_response :conflict
  end

  test "start refuses an unknown mode and an unavailable one" do
    post "/api/v1/live_conversations", params: { mode: "video" }, headers: @headers
    assert_response :unprocessable_entity

    stub_live_root(root: nil)
    post "/api/v1/live_conversations", params: { mode: "voice" }, headers: @headers
    assert_response :service_unavailable
    assert_match(/live-mode/, response.parsed_body["message"])
  end

  test "switching mode mid-conversation: voice on, then the secret; voice off, then typing" do
    conversation = create_live_conversation(mode: "text")
    LiveConversations::RealtimeSession.stubs(:mint).returns({ client_secret: "ek_switch" })

    post "/api/v1/live_conversations/#{conversation.id}/client_secret", headers: @headers
    assert_response :conflict

    post "/api/v1/live_conversations/#{conversation.id}/mode", params: { mode: "voice" }, headers: @headers
    assert_response :success
    assert_equal "voice", response.parsed_body["mode"]
    assert_equal "gpt-realtime-2.1-mini", response.parsed_body["model"]
    get "/api/v1/live_conversations", headers: @headers
    assert_equal({ "voice" => conversation.id }, response.parsed_body["current"])

    post "/api/v1/live_conversations/#{conversation.id}/client_secret", headers: @headers
    assert_equal "ek_switch", response.parsed_body["client_secret"]
    post "/api/v1/live_conversations/#{conversation.id}/messages", params: { content: "typed?" }, headers: @headers
    assert_response :unprocessable_entity

    post "/api/v1/live_conversations/#{conversation.id}/mode", params: { mode: "text" }, headers: @headers
    post "/api/v1/live_conversations/#{conversation.id}/messages", params: { content: "typed." }, headers: @headers
    assert_response :created

    post "/api/v1/live_conversations/#{conversation.id}/mode", params: { mode: "video" }, headers: @headers
    assert_response :unprocessable_entity
  end

  test "voice relay over the API: secret, tool call that enables a server, transcript" do
    stub_clock_server
    conversation = create_live_conversation(mode: "voice")
    LiveConversations::RealtimeSession.stubs(:mint).returns({ client_secret: "ek_api", websocket_url: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini" })

    post "/api/v1/live_conversations/#{conversation.id}/client_secret", headers: @headers
    assert_equal "ek_api", response.parsed_body["client_secret"]

    post "/api/v1/live_conversations/#{conversation.id}/tool_calls",
      params: { name: "enable_mcp_server", arguments: { name: "test-clock" }.to_json, call_id: "call_e" }, headers: @headers
    assert_response :success
    assert response.parsed_body["tools_changed"]
    assert_includes response.parsed_body["tools"].map { |t| t["name"] }, "test-clock__current_time"

    post "/api/v1/live_conversations/#{conversation.id}/turns", params: { role: "assistant", content: "Clock is on." }, headers: @headers
    assert_response :created
    assert response.parsed_body["respond"]
  end

  test "with Listening gated, an app that asks for its own replies has a stray line dropped and a named one answered" do
    LiveConversations::SettingsUpdate.call({ "voice_listening" => "wake_word" }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    conversation = create_live_conversation(mode: "voice")

    post "/api/v1/live_conversations/#{conversation.id}/turns", params: { role: "user", content: "talking to my friend", listening_modes: "1" }, headers: @headers
    assert_response :ok
    assert_equal({ "respond" => false, "dropped" => true }, response.parsed_body)

    post "/api/v1/live_conversations/#{conversation.id}/turns", params: { role: "user", content: "Zimmer, is main green?", listening_modes: "1" }, headers: @headers
    assert_response :created
    assert_equal [ true, "Zimmer, is main green?" ], response.parsed_body.values_at("respond", "content")
    assert_equal [ "Zimmer, is main green?" ], conversation.turns.map(&:content)
  end

  test "Live settings over the API: a key reads, only a person on the app writes, and a voice call gets its session.update" do
    get "/api/v1/live/settings", headers: @key_headers
    assert_response :success
    body = response.parsed_body
    assert_in_delta 1.0, body.dig("settings", "voice_speed")
    speed = body["fields"].find { |f| f["key"] == "voice_speed" }
    assert_equal [ 0.25, 1.5 ], [ speed["min"], speed["max"] ]
    assert speed["mid_call"]
    assert_includes body["fields"].find { |f| f["key"] == "voice_model" }["options"].map { |o| o["value"] }, "gpt-realtime-2.1"

    patch "/api/v1/live/settings", params: { voice_speed: 1.3 }, headers: @key_headers
    assert_response :forbidden

    patch "/api/v1/live/settings", params: { voice_speed: 1.3, guidance: "Be brief." }, headers: @headers
    assert_response :success
    assert response.parsed_body["changed"]
    assert_in_delta 1.3, response.parsed_body.dig("settings", "voice_speed")
    assert_equal "Be brief.", response.parsed_body["guidance"]
    change = LiveSettingChange.sole
    assert_equal [ "human", "the iOS app" ], [ change.actor_kind, change.actor ]
    assert_equal change.id, response.parsed_body["history"].first["id"]

    patch "/api/v1/live/settings", params: { voice_model: "gpt-9" }, headers: @headers
    assert_response :unprocessable_entity
    patch "/api/v1/live/settings", params: { voice_sped: 1.1 }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_match(/Unknown setting "voice_sped"/, response.parsed_body["message"])

    conversation = create_live_conversation(mode: "voice")
    post "/api/v1/live_conversations/#{conversation.id}/session_update", headers: @headers
    assert_response :success
    assert_in_delta 1.3, response.parsed_body.dig("session", "audio", "output", "speed")
    assert response.parsed_body.dig("session", "instructions").end_with?("Be brief.")

    patch "/api/v1/live/settings", params: { guidance: "Oops." }, headers: @headers
    post "/api/v1/live/settings/changes/#{LiveSettingChange.recent_first.first.id}/restore_guidance", headers: @headers
    assert_equal "Be brief.", response.parsed_body["guidance"]

    post "/api/v1/live/settings/reset", headers: @headers
    assert_in_delta 1.0, response.parsed_body.dig("settings", "voice_speed")
    assert_equal "Be brief.", response.parsed_body["guidance"]
  end

  test "a voice tool call that changes the settings hands the client a session.update" do
    conversation = create_live_conversation(mode: "voice")

    post "/api/v1/live_conversations/#{conversation.id}/tool_calls",
      params: { name: "update_live_settings", arguments: { voice_speed: 1.4 }.to_json, call_id: "call_s" }, headers: @headers

    assert_response :success
    assert_in_delta 1.4, response.parsed_body.dig("session", "audio", "output", "speed")
    assert_nil response.parsed_body.dig("session", "model")
  end

  test "the sessions a conversation has touched come back newest first with their board rows, on a key or the app" do
    conversation = create_live_conversation(mode: "voice")
    started = create_session(title: "Investigate the flaky poller test", status: :running)
    SessionStatusSummary.create!(session: started, state: "ready", summary: "Reading the **poller** spec.", generated_at: Time.current)
    checked = create_session(title: "Which Postgres?", status: :needs_input)
    conversation.turns.create!(role: "tool", tool_name: "zimmer", call_id: "c1", tool_arguments: { "tool" => "quick_router" },
                               tool_output: "- **ID:** #{started.id}\n- **URL:** http://example.com/sessions/#{started.id}")
    conversation.turns.create!(role: "tool", tool_name: "zimmer", call_id: "c2", tool_arguments: { "tool" => "get_session", "arguments" => { "id" => checked.id } }, tool_output: "## Session")
    conversation.turns.create!(role: "tool", tool_name: "zimmer", call_id: "c3", tool_arguments: { "tool" => "get_session", "arguments" => { "id" => 0 } }, tool_output: "no such session")

    get "/api/v1/live_conversations/#{conversation.id}/sessions", headers: @key_headers
    assert_response :success
    body = response.parsed_body
    assert_equal [ checked.id, started.id ], body["sessions"].map { |s| s["id"] }, "most recently named first; an id that is no session is skipped"
    assert_equal "needs_input", body["sessions"].first["status"]
    assert_equal "Reading the **poller** spec.", body.dig("board_rows", started.id.to_s, "status_summary", "summary")
    assert_nil body.dig("board_rows", checked.id.to_s, "status_summary")

    get "/api/v1/live_conversations/#{conversation.id}/sessions", headers: @headers
    assert_response :success
    assert_equal 2, response.parsed_body["sessions"].size

    get "/api/v1/live_conversations/#{conversation.id}/sessions"
    assert_response :unauthorized
  end

  test "an unknown conversation is a 404" do
    get "/api/v1/live_conversations/999999", headers: @headers
    assert_response :not_found
  end

  private

  def pkce
    verifier = SecureRandom.urlsafe_base64(48)
    [ verifier, Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) ]
  end

  def app_token(privilege:)
    verifier, challenge = pkce
    post "/oauth/authorize", params: { response_type: "code", client_id: OauthServer::NativeApp::CLIENT_ID, redirect_uri: OauthServer::NativeApp::REDIRECT_URI,
      code_challenge: challenge, code_challenge_method: "S256", state: "s1", resource: "#{ISSUER}/mcp", scope: "mcp",
      decision: "approve", privilege: privilege }
    assert_response :found
    code = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("code")
    post "/oauth/token", params: { grant_type: "authorization_code", client_id: OauthServer::NativeApp::CLIENT_ID, code: code,
      code_verifier: verifier, redirect_uri: OauthServer::NativeApp::REDIRECT_URI, resource: "#{ISSUER}/mcp" }
    assert_response :success
    JSON.parse(response.body).fetch("access_token")
  end

  def bearer(access_token) = { "Authorization" => "Bearer #{access_token}" }
end
