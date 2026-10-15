# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Api::V1::LiveConversationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_env = ENV[ApiKey::ENV_VAR]
    ENV[ApiKey::ENV_VAR] = "live-api-test-key"
    @headers = { "X-API-Key" => "live-api-test-key" }
    stub_live_roots
    stub_live_key
  end

  teardown do
    @original_env.nil? ? ENV.delete(ApiKey::ENV_VAR) : ENV[ApiKey::ENV_VAR] = @original_env
  end

  test "requires an API key" do
    get "/api/v1/live"
    assert_response :unauthorized
  end

  test "modes report availability and why not" do
    stub_live_roots(voice: nil)

    get "/api/v1/live", headers: @headers

    assert_response :success
    modes = response.parsed_body["modes"].index_by { |m| m["mode"] }
    assert modes["text"]["available"]
    assert_not modes["voice"]["available"]
    assert_match(/live-voice/, modes["voice"]["reasons"].first)
  end

  test "start, message, read the thread, and end" do
    assert_enqueued_with(job: LiveConversationPrepareJob) do
      post "/api/v1/live_conversations", params: { mode: "text" }, headers: @headers
    end
    assert_response :created
    id = response.parsed_body["id"]
    assert_equal "preparing", response.parsed_body["status"]

    # Typed while preparing: accepted, answered once active.
    post "/api/v1/live_conversations/#{id}/messages", params: { content: "hello" }, headers: @headers
    assert_response :created
    first_turn = response.parsed_body["id"]

    get "/api/v1/live_conversations", headers: @headers
    assert_equal id, response.parsed_body.dig("current", "text")

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

    stub_live_roots(voice: nil)
    post "/api/v1/live_conversations", params: { mode: "voice" }, headers: @headers
    assert_response :service_unavailable
    assert_match(/live-voice/, response.parsed_body["message"])
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
  end

  test "an unknown conversation is a 404" do
    get "/api/v1/live_conversations/999999", headers: @headers
    assert_response :not_found
  end
end
