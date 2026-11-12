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

  test "minting a secret and refreshing a call record the client driving it, so the car's instructions say so" do
    conversation = create_live_conversation(mode: "voice", client_surface: "ios")
    minted_for = nil
    LiveConversations::RealtimeSession.stubs(:mint).with { |*args| minted_for = args.first.client_surface; true }.returns({ client_secret: "ek_car" })
    car = @headers.merge("X-Zimmer-Client" => "carplay/1.4.2")

    post "/api/v1/live_conversations/#{conversation.id}/client_secret", headers: car
    assert_response :success
    assert_equal "carplay", minted_for, "noted before the secret's instructions are built"
    assert_equal "carplay", conversation.reload.client_surface

    post "/api/v1/live_conversations/#{conversation.id}/session_update", headers: @headers
    assert_response :success
    assert_equal "ios", conversation.reload.client_surface, "the phone took the call back"
    refute_match(/client driving this conversation right now is CarPlay/, response.parsed_body.dig("session", "instructions"))

    post "/api/v1/live_conversations/#{conversation.id}/session_update", headers: car
    assert_equal "carplay", conversation.reload.client_surface
    assert_match(/client driving this conversation right now is CarPlay/, response.parsed_body.dig("session", "instructions"))
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

  test "a hang-up relayed by an app that closes its call answers hang_up; an older app is refused" do
    conversation = create_live_conversation(mode: "voice")
    car = @headers.merge("X-Zimmer-Client" => "carplay/1.6.0")

    post "/api/v1/live_conversations/#{conversation.id}/tool_calls",
      params: { name: "hang_up", arguments: "{}", call_id: "call_h", reattaches: "1", hangs_up: "1" }, headers: car
    assert_response :success
    assert_equal true, response.parsed_body["hang_up"]
    assert_equal false, response.parsed_body["error"]
    assert_nil response.parsed_body["tools"]
    assert conversation.reload.active?, "hanging up ends the call, not the conversation"

    post "/api/v1/live_conversations/#{conversation.id}/tool_calls",
      params: { name: "hang_up", arguments: "{}", call_id: "call_h2", reattaches: "1" }, headers: car
    assert_response :success
    assert_nil response.parsed_body["hang_up"]
    assert_equal true, response.parsed_body["error"]
    assert_match(/tap End/, response.parsed_body["output"])
  end

  test "the car answers every line: a gated Listening setting gates the phone's call, never the car's" do
    LiveConversations::SettingsUpdate.call({ "voice_listening" => "wake_word" }, actor: LiveConversations::SettingsUpdate::Actor.agent("live conversation #1"))
    conversation = create_live_conversation(mode: "voice")
    car = @headers.merge("X-Zimmer-Client" => "carplay/1.5.0")
    phone = @headers.merge("X-Zimmer-Client" => "ios/1.5.0")

    post "/api/v1/live_conversations/#{conversation.id}/session_update", params: { listening_modes: "1" }, headers: phone
    assert_equal false, response.parsed_body.dig("session", "audio", "input", "turn_detection", "create_response"), "the phone asks for its own replies"

    post "/api/v1/live_conversations/#{conversation.id}/session_update", params: { listening_modes: "1" }, headers: car
    assert_equal({ "type" => "semantic_vad", "eagerness" => "auto", "create_response" => true, "interrupt_response" => true },
                 response.parsed_body.dig("session", "audio", "input", "turn_detection"),
                 "handed to the car, OpenAI ends each turn and answers it")

    post "/api/v1/live_conversations/#{conversation.id}/turns", params: { role: "user", content: "talking to my friend", listening_modes: "1" }, headers: car
    assert_response :created
    assert response.parsed_body["respond"], "no line is dropped in the car"
  end

  # What call 90fb7c5f did on a stored gated mode: the car hung up, the call carried
  # on through the phone, and every line was heard and dropped.
  test "a call handed from the car to the phone keeps answering every line until it hangs up" do
    LiveConversations::SettingsUpdate.call({ "voice_listening" => "dynamic" }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    conversation = create_live_conversation(mode: "voice")
    car = @headers.merge("X-Zimmer-Client" => "carplay/1.5.0")
    phone = @headers.merge("X-Zimmer-Client" => "ios/1.5.0")
    url = "/api/v1/live_conversations/#{conversation.id}"
    LiveConversations::RealtimeSession.any_instance.stubs(:create_secret).returns({ "value" => "ek_test" })
    OpenaiClient.any_instance.expects(:chat_completion).never

    post "#{url}/client_secret", params: { listening_modes: "1" }, headers: car
    assert_equal "always", response.parsed_body["listening"]

    post "#{url}/session_update", params: { listening_modes: "1" }, headers: phone
    assert_equal({ "type" => "semantic_vad", "eagerness" => "auto", "create_response" => true, "interrupt_response" => true },
                 response.parsed_body.dig("session", "audio", "input", "turn_detection"))
    assert_equal "ios", conversation.reload.client_surface, "the hand-over is still noted: the instructions stop saying car"

    post "#{url}/turns", params: { role: "user", content: "are you still there", listening_modes: "1" }, headers: phone
    assert_response :created
    assert_equal [ true, false, "always" ], response.parsed_body.values_at("respond", "dropped", "listening")

    post "#{url}/tool_calls", params: { name: "update_live_settings", arguments: { voice_speed: 1.1 }.to_json, call_id: "call_s", listening_modes: "1" }, headers: phone
    assert_equal true, response.parsed_body.dig("session", "audio", "input", "turn_detection", "create_response"), "a mid-call setting change does not gate it either"

    post "#{url}/session_update", params: { listening_modes: "1" }, headers: phone
    assert_equal true, response.parsed_body.dig("session", "audio", "input", "turn_detection", "create_response"), "nor the settings screen's refresh"

    post "#{url}/client_secret", params: { listening_modes: "1" }, headers: phone
    assert_equal "dynamic", response.parsed_body["listening"], "the next call, started on the phone, is on Listening again"
    assert_not conversation.reload.car_call

    post "#{url}/session_update", params: { listening_modes: "1" }, headers: phone
    assert_equal false, response.parsed_body.dig("session", "audio", "input", "turn_detection", "create_response")
  end

  test "a phone call handed to the car and back stays on Always for the rest of the call" do
    LiveConversations::SettingsUpdate.call({ "voice_listening" => "wake_word" }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    conversation = create_live_conversation(mode: "voice", client_surface: "ios")
    url = "/api/v1/live_conversations/#{conversation.id}"
    LiveConversations::RealtimeSession.any_instance.stubs(:create_secret).returns({ "value" => "ek_test" })
    phone = @headers.merge("X-Zimmer-Client" => "ios/1.5.0")
    car = @headers.merge("X-Zimmer-Client" => "carplay/1.5.0")

    post "#{url}/client_secret", params: { listening_modes: "1" }, headers: phone
    assert_equal "wake_word", response.parsed_body["listening"]

    post "#{url}/session_update", params: { listening_modes: "1" }, headers: car
    assert_equal true, response.parsed_body.dig("session", "audio", "input", "turn_detection", "create_response")

    post "#{url}/session_update", params: { listening_modes: "1" }, headers: phone
    assert_equal true, response.parsed_body.dig("session", "audio", "input", "turn_detection", "create_response")
  end

  test "a line from the car holds the call on Always even when the hand-over's session_update never landed" do
    LiveConversations::SettingsUpdate.call({ "voice_listening" => "wake_word" }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    conversation = create_live_conversation(mode: "voice", client_surface: "ios")
    url = "/api/v1/live_conversations/#{conversation.id}"
    phone = @headers.merge("X-Zimmer-Client" => "ios/1.5.0")

    post "#{url}/turns", params: { role: "user", content: "talking to my friend", listening_modes: "1" }, headers: @headers.merge("X-Zimmer-Client" => "carplay/1.5.0")
    assert_response :created
    assert_equal "ios", conversation.reload.client_surface, "a late line from the car does not take the call back"

    post "#{url}/session_update", params: { listening_modes: "1" }, headers: phone
    assert_equal true, response.parsed_body.dig("session", "audio", "input", "turn_detection", "create_response")
  end

  test "a dropped line says the mode that dropped it" do
    LiveConversations::SettingsUpdate.call({ "voice_listening" => "wake_word" }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    conversation = create_live_conversation(mode: "voice")

    post "/api/v1/live_conversations/#{conversation.id}/turns", params: { role: "user", content: "talking to my friend", listening_modes: "1" }, headers: @headers.merge("X-Zimmer-Client" => "ios/1.5.0")

    assert_equal "wake_word", response.parsed_body["listening"]
  end

  test "with Listening gated, an app that asks for its own replies has a stray line dropped and a named one answered" do
    LiveConversations::SettingsUpdate.call({ "voice_listening" => "wake_word" }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    conversation = create_live_conversation(mode: "voice")

    post "/api/v1/live_conversations/#{conversation.id}/turns", params: { role: "user", content: "talking to my friend", listening_modes: "1" }, headers: @headers
    assert_response :ok
    assert_equal({ "respond" => false, "dropped" => true, "listening" => "wake_word" }, response.parsed_body)

    post "/api/v1/live_conversations/#{conversation.id}/turns", params: { role: "user", content: "Zimmer, is main green?", listening_modes: "1" }, headers: @headers
    assert_response :created
    assert_equal [ true, "Zimmer, is main green?" ], response.parsed_body.values_at("respond", "content")
    assert_equal [ "Zimmer, is main green?" ], conversation.turns.map(&:content)
  end

  test "Live settings over the API say which settings the mode leaves unused, and which of a write had no effect" do
    get "/api/v1/live/settings", headers: @key_headers
    body = response.parsed_body
    assert_equal %w[voice_vad_threshold voice_vad_prefix_padding_ms voice_vad_silence_duration_ms], body["inactive"]
    assert_equal "server_vad", body["fields"].find { |f| f["key"] == "voice_vad_threshold" }["applies_under"]
    assert_equal "semantic_vad", body["fields"].find { |f| f["key"] == "voice_vad_eagerness" }["applies_under"]
    assert_not body["fields"].find { |f| f["key"] == "voice_speed" }.key?("applies_under")

    patch "/api/v1/live/settings", params: { voice_vad_threshold: 0.75 }, headers: @headers
    assert_response :success
    assert response.parsed_body["changed"]
    assert_equal %w[voice_vad_threshold], response.parsed_body["no_effect"]
    assert_match(/Threshold \(silence\) has no effect under Semantic turn detection/, response.parsed_body["summary"])

    patch "/api/v1/live/settings", params: { voice_speed: 1.1 }, headers: @headers
    assert_empty response.parsed_body["no_effect"]
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

  # The car's voice settings panel writes what `update_live_settings` wrote, and the
  # cap, which only this API can set, the way the app sends it: a JSON null on each key, which SettingsUpdate takes as
  # back on the default. The panel is only a break-glass if this is the same row.
  test "a cap and a gated Listening are read and cleared over the API, and the next call has no cap" do
    conversation = create_live_conversation(mode: "voice")
    by_voice = { voice_listening: "dynamic", voice_vad_eagerness: "low", voice_vad_threshold: 0.92 }
    post "/api/v1/live_conversations/#{conversation.id}/tool_calls",
      params: { name: "update_live_settings", arguments: by_voice.to_json, call_id: "call_voice" }, headers: @headers
    assert_response :success
    # The cap is the one setting voice cannot write: it counts the tool calls that would undo it.
    patch "/api/v1/live/settings", params: { voice_max_output_tokens: 2_048 }, headers: @headers, as: :json
    assert_response :success
    written = by_voice.merge(voice_max_output_tokens: 2_048)

    get "/api/v1/live/settings", headers: @headers
    assert_equal 2_048, response.parsed_body.dig("settings", "voice_max_output_tokens")
    assert_equal "dynamic", response.parsed_body.dig("settings", "voice_listening")
    assert_equal written.keys.map(&:to_s).sort, response.parsed_body["overrides"].sort
    assert_equal 2_048, LiveConversations::RealtimeSession.new(conversation).session_config[:max_output_tokens]

    patch "/api/v1/live/settings", params: written.transform_values { nil }, headers: @headers, as: :json
    assert_response :success
    assert_empty response.parsed_body["overrides"]
    assert_equal "always", response.parsed_body.dig("settings", "voice_listening")
    assert_nil response.parsed_body.dig("settings", "voice_max_output_tokens")
    assert_equal [ "human", "the iOS app" ], LiveSettingChange.recent_first.first.then { |c| [ c.actor_kind, c.actor ] }

    config = LiveConversations::RealtimeSession.new(conversation, setting: LiveSetting.current).session_config
    assert_not config.key?(:max_output_tokens), "a call minted after the reset has no cap"
    assert_equal({ type: "semantic_vad", eagerness: "auto", create_response: true, interrupt_response: true },
      config.dig(:audio, :input, :turn_detection))
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
    # Not `create_session`: in an integration test that name is Rails' own, and makes a request session.
    started = Session.create!(title: "Investigate the flaky poller test", status: :running, prompt: "Look into it", agent_runtime: "claude_code",
                              git_root: "https://github.com/test/repo.git", branch: "main")
    SessionStatusSummary.create!(session: started, state: "ready", summary: "Reading the **poller** spec.", generated_at: Time.current)
    checked = Session.create!(title: "Which Postgres?", status: :needs_input, prompt: "Pick one", agent_runtime: "claude_code",
                              git_root: "https://github.com/test/repo.git", branch: "main")
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

  test "switch goes back and says so, and the conversation it left is ended" do
    old = create_live_conversation(status: LiveConversation::ENDED, ended_at: 1.hour.ago)
    old.turns.create!(role: "user", source: "typed", content: "Is main green right now")
    current = create_live_conversation

    post switch_api_v1_live_conversations_url, params: {}, headers: @headers, as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal old.id, body["id"]
    assert_equal true, body["switched"]
    assert_equal "active", body["status"]
    assert current.reload.ended?
  end

  test "switch refusals carry their status" do
    current = create_live_conversation
    failed = create_live_conversation(status: LiveConversation::FAILED)

    post switch_api_v1_live_conversations_url, params: { id: 0 }, headers: @headers, as: :json
    assert_response :not_found
    post switch_api_v1_live_conversations_url, params: { id: failed.id }, headers: @headers, as: :json
    assert_response :conflict
    post switch_api_v1_live_conversations_url, params: { id: current.id }, headers: @headers, as: :json
    assert_response :success
    assert_equal false, response.parsed_body["switched"]
  end

  test "a tool call that switches answers where it went and nothing else to send" do
    old = create_live_conversation(status: LiveConversation::ENDED, ended_at: 1.hour.ago, mode: "voice")
    old.turns.create!(role: "user", source: "spoken", content: "Deploy the fix to staging")
    current = create_live_conversation(mode: "voice")

    post tool_calls_api_v1_live_conversation_url(current), params: { name: "switch_live_conversation", arguments: "{}", call_id: "c1", reattaches: 1 },
                                                           headers: @headers, as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal({ "id" => old.id, "title" => "Deploy the fix to staging" }, body["switched_to"])
    assert_nil body["session"]
  end

  test "a tool call from an app that cannot reattach is refused the switch" do
    old = create_live_conversation(status: LiveConversation::ENDED, ended_at: 1.hour.ago)
    old.turns.create!(role: "user", source: "typed", content: "Is main green right now")
    current = create_live_conversation(mode: "voice")

    post tool_calls_api_v1_live_conversation_url(current), params: { name: "switch_live_conversation", arguments: "{}", call_id: "c1" }, headers: @headers, as: :json

    assert_response :success
    assert_equal true, response.parsed_body["error"]
    assert current.reload.active?
  end

  test "the old conversation stops taking turns once it has been left" do
    old = create_live_conversation(status: LiveConversation::ENDED, ended_at: 1.hour.ago)
    old.turns.create!(role: "user", source: "typed", content: "Is main green right now")
    current = create_live_conversation(mode: "voice")
    LiveConversations::Switch.call(old.id)

    post turns_api_v1_live_conversation_url(current), params: { role: "user", content: "still here?" }, headers: @headers, as: :json

    assert_response :conflict
    assert_empty current.turns
  end

  test "a fleet API key cannot switch" do
    create_live_conversation

    post switch_api_v1_live_conversations_url, params: {}, headers: @key_headers, as: :json

    assert_includes [ 401, 403 ], response.status
  end
end
