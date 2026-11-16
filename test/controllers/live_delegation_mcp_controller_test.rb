# frozen_string_literal: true

require "test_helper"

class LiveDelegationMcpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @conversation = create_live_conversation(mode: "voice", voice_engine: "gpt_live_claude")
    @token = LiveConversations::DelegationToken.mint(@conversation, delegation_id: "item_del_9")
  end

  def rpc(method, params = {}, token: @token, headers: {})
    auth = token ? { "Authorization" => "Bearer #{token}" } : {}
    post "/live/delegation_mcp", params: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json,
                                 headers: { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }.merge(auth, headers)
  end

  test "serves this conversation's voice tools to a delegation token" do
    rpc("tools/list")

    assert_response :success
    names = response.parsed_body.dig("result", "tools").map { |tool| tool["name"] }
    assert_includes names, "get_live_settings"
    assert_includes names, "hang_up"
    assert_includes names, "zimmer"
  end

  test "a call runs through ToolBridge, is recorded as a tool turn, and is one tool_call row on the ledger" do
    rpc("tools/call", { name: "get_live_settings", arguments: {} })

    assert_response :success
    result = response.parsed_body["result"]
    assert_not result["isError"]
    assert_includes result.dig("content", 0, "text"), "voice_engine"
    assert_equal "get_live_settings", @conversation.turns.where(role: "tool").last.tool_name
    row = LiveUsageEvent.find_by!(operation: "tool_call")
    assert_equal [ "gpt_live_claude", "zimmer", "get_live_settings" ], row.values_at(:engine, :vendor, :model)
    assert_equal "item_del_9", row.details["delegation_id"]
  end

  test "hang_up through the endpoint is recorded, so the delegate can end the call" do
    rpc("tools/call", { name: "hang_up", arguments: {} })

    assert_response :success
    assert @conversation.turns.where(role: "tool", tool_name: "hang_up", tool_error: false).exists?
  end

  test "refuses no token, a tampered or expired one, and an API key" do
    rpc("tools/list", token: nil)
    assert_response :unauthorized

    rpc("tools/list", token: "#{@token}x")
    assert_response :unauthorized

    travel_to(LiveConversations::DelegationToken::TTL.from_now + 1.second) do
      rpc("tools/list")
      assert_response :unauthorized
    end

    previous = ENV[ApiKey::ENV_VAR]
    ENV[ApiKey::ENV_VAR] = "delegation-test-key"
    rpc("tools/list", token: nil, headers: { "X-API-Key" => "delegation-test-key" })
    assert_response :unauthorized
    rpc("tools/list", token: "delegation-test-key")
    assert_response :unauthorized
  ensure
    previous.nil? ? ENV.delete(ApiKey::ENV_VAR) : ENV[ApiKey::ENV_VAR] = previous
  end

  test "a token for a conversation that no longer exists opens nothing" do
    token = LiveConversations::DelegationToken.mint(@conversation, delegation_id: "d")
    @conversation.destroy!

    rpc("tools/list", token: token)
    assert_response :unauthorized
  end
end
