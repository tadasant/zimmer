# frozen_string_literal: true

require "test_helper"

# Drives the native MCP endpoint the way an MCP client does: JSON-RPC over
# POST /mcp, with the API key the rest of the API uses.
class McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
    @headers = { "X-API-Key" => @api_key, "Content-Type" => "application/json" }
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  def rpc(method, params = {}, id: 1, headers: @headers, path: "/mcp")
    post path, params: { jsonrpc: "2.0", id: id, method: method, params: params }.to_json, headers: headers
    response.body.presence && JSON.parse(response.body)
  end

  # --- Auth ---

  test "rejects a request with no API key" do
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
                 headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
  end

  test "rejects a request with the wrong API key" do
    rpc("tools/list", headers: { "X-API-Key" => "nope", "Content-Type" => "application/json" })
    assert_response :unauthorized
  end

  test "accepts the API key as a bearer token" do
    body = rpc("tools/list", headers: { "Authorization" => "Bearer #{@api_key}", "Content-Type" => "application/json" })
    assert_response :success
    assert body["result"]["tools"].any?
  end

  # --- Protocol ---

  test "initialize echoes a supported protocol version and advertises tools" do
    body = rpc("initialize", { "protocolVersion" => "2025-03-26", "capabilities" => {} })
    assert_response :success
    assert_equal "2025-03-26", body["result"]["protocolVersion"]
    assert_equal "zimmer", body["result"]["serverInfo"]["name"]
    assert body["result"]["capabilities"].key?("tools")
  end

  test "initialize falls back to the latest protocol version for an unknown request" do
    body = rpc("initialize", { "protocolVersion" => "1999-01-01" })
    assert_equal Mcp::Server::LATEST_PROTOCOL_VERSION, body["result"]["protocolVersion"]
  end

  test "notifications get an empty 202" do
    post "/mcp", params: { jsonrpc: "2.0", method: "notifications/initialized" }.to_json, headers: @headers
    assert_response :accepted
    assert_predicate response.body, :blank?
  end

  test "ping answers with an empty result" do
    assert_equal({}, rpc("ping")["result"])
  end

  test "unknown method returns JSON-RPC method-not-found" do
    body = rpc("resources/list")
    assert_equal Mcp::JsonRpc::METHOD_NOT_FOUND, body["error"]["code"]
  end

  test "malformed JSON returns a parse error" do
    post "/mcp", params: "{not json", headers: @headers
    assert_response :bad_request
    assert_equal Mcp::JsonRpc::PARSE_ERROR, JSON.parse(response.body)["error"]["code"]
  end

  test "GET is rejected: this transport has no server-initiated stream" do
    get "/mcp", headers: @headers
    assert_response :method_not_allowed
  end

  # --- Tool listing and scoping ---

  test "tools/list returns the full surface by default" do
    tools = rpc("tools/list")["result"]["tools"].map { |t| t["name"] }
    assert_equal Mcp::Registry::ALL_TOOLS.size, tools.size
    assert_includes tools, "start_session"
    assert_includes tools, "action_health"
    assert_includes tools, "wake_me_up_later"
  end

  test "tools/list is scoped by tool_groups" do
    tools = rpc("tools/list", path: "/mcp?tool_groups=self_session")["result"]["tools"].map { |t| t["name"] }

    assert_equal %w[get_session get_configs action_session send_push_notification wake_me_up_later
                    wake_me_up_when_session_changes_state].sort, tools.sort
    refute_includes tools, "start_session"
  end

  test "tools/list readonly group drops write tools" do
    tools = rpc("tools/list", path: "/mcp?tool_groups=sessions_readonly")["result"]["tools"].map { |t| t["name"] }

    assert_includes tools, "quick_search_sessions"
    refute_includes tools, "start_session"
    refute_includes tools, "action_session"
  end

  test "every tool advertises a name, description and object input schema" do
    rpc("tools/list")["result"]["tools"].each do |tool|
      assert tool["name"].present?, "tool missing name"
      assert tool["description"].present?, "#{tool['name']} missing description"
      assert_equal "object", tool["inputSchema"]["type"], "#{tool['name']} schema is not an object"
    end
  end

  # --- Tool calls ---

  test "tools/call runs a tool and returns text content" do
    body = rpc("tools/call", { "name" => "get_configs", "arguments" => {} })

    assert_response :success
    refute body["result"]["isError"]
    assert_includes body["result"]["content"].first["text"], "## MCP Servers"
  end

  test "tools/call surfaces a tool error as an error result, not a protocol error" do
    body = rpc("tools/call", { "name" => "get_session", "arguments" => { "id" => "999999999" } })

    assert body["result"]["isError"], "expected isError for a missing session"
    assert_match(/not found/i, body["result"]["content"].first["text"])
    assert_nil body["error"]
  end

  test "tools/call on a tool outside the enabled groups is rejected" do
    body = rpc("tools/call", { "name" => "start_session", "arguments" => {} }, path: "/mcp?tool_groups=self_session")

    assert_equal Mcp::JsonRpc::INVALID_PARAMS, body["error"]["code"]
    assert_match(/Unknown tool/, body["error"]["message"])
  end

  test "a batch of messages is answered with a batch of responses" do
    post "/mcp", params: [
      { jsonrpc: "2.0", id: 1, method: "ping" },
      { jsonrpc: "2.0", id: 2, method: "tools/list" }
    ].to_json, headers: @headers

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ 1, 2 ], body.map { |m| m["id"] }
  end

  # --- allowed_agent_roots scoping ---

  test "a scoped connection cannot widen itself by putting tool_groups in the body" do
    post "/mcp?tool_groups=self_session",
         params: { jsonrpc: "2.0", id: 1, method: "tools/list", tool_groups: "sessions" }.to_json,
         headers: @headers

    tools = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
    refute_includes tools, "start_session", "body params must not override the URL's scoping"
  end

  test "a restricted connection cannot widen allowed_agent_roots from the body" do
    post "/mcp?allowed_agent_roots=zimmer",
         params: { jsonrpc: "2.0", id: 1, method: "tools/call", allowed_agent_roots: "general-agent",
                   params: { name: "start_session", arguments: { agent_root: "general-agent", prompt: "x" } } }.to_json,
         headers: @headers

    result = JSON.parse(response.body)["result"]
    assert result["isError"], "start_session on a disallowed root must be refused"
    assert_match(/not permitted/, result["content"].first["text"])
  end

  test "get_configs hides agent roots outside allowed_agent_roots" do
    body = rpc("tools/call", { "name" => "get_configs", "arguments" => {} }, path: "/mcp?allowed_agent_roots=zimmer")
    text = body["result"]["content"].first["text"]

    assert_includes text, "`zimmer`"
    refute_includes text, "`general-agent`"
  end
end
