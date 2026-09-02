# frozen_string_literal: true

require "test_helper"

# Drives the native MCP endpoint the way an MCP client does: JSON-RPC over
# POST /mcp, with the API key the rest of the API uses.
class McpControllerTest < ActionDispatch::IntegrationTest
  setup do
    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
    # What an MCP client sends: JSON body, and an Accept that allows either a JSON
    # response or an SSE frame.
    @headers = {
      "X-API-Key" => @api_key,
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  def initialize_params(protocol_version)
    {
      "protocolVersion" => protocol_version,
      "capabilities" => {},
      "clientInfo" => { "name" => "test-client", "version" => "1.0" }
    }
  end

  def rpc(method, params = {}, id: 1, headers: @headers, path: "/mcp")
    post path, params: { jsonrpc: "2.0", id: id, method: method, params: params }.to_json, headers: headers
    response.body.presence && JSON.parse(response.body)
  end

  # --- Auth ---

  test "rejects a request with no API key" do
    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
                 headers: @headers.except("X-API-Key")
    assert_response :unauthorized
  end

  test "rejects a request with the wrong API key" do
    rpc("tools/list", headers: @headers.merge("X-API-Key" => "nope"))
    assert_response :unauthorized
  end

  test "accepts the API key as a bearer token" do
    body = rpc("tools/list", headers: @headers.except("X-API-Key").merge("Authorization" => "Bearer #{@api_key}"))
    assert_response :success
    assert body["result"]["tools"].any?
  end

  test "accepts a client that only accepts JSON" do
    body = rpc("tools/list", headers: @headers.merge("Accept" => "application/json"))
    assert_response :success
    assert body["result"]["tools"].any?
  end

  # --- Protocol ---

  test "initialize echoes a supported protocol version and advertises tools" do
    body = rpc("initialize", initialize_params("2025-03-26"))
    assert_response :success
    assert_equal "2025-03-26", body["result"]["protocolVersion"]
    assert_equal "zimmer", body["result"]["serverInfo"]["name"]
    assert body["result"]["capabilities"].key?("tools")
  end

  test "initialize answers an unknown requested version with a supported one" do
    body = rpc("initialize", initialize_params("1999-01-01"))
    assert_includes MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS, body["result"]["protocolVersion"]
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
    body = rpc("zimmer/nope")
    assert_equal(-32601, body["error"]["code"])
  end

  test "malformed JSON returns a parse error" do
    post "/mcp", params: "{not json", headers: @headers
    assert_response :bad_request
    assert_equal(-32700, JSON.parse(response.body)["error"]["code"])
  end

  test "GET is rejected: this transport has no server-initiated stream" do
    get "/mcp", headers: @headers
    assert_response :method_not_allowed
  end

  # --- Tool listing and scoping ---

  test "tools/list returns the base-group surface by default" do
    tools = rpc("tools/list")["result"]["tools"].map { |t| t["name"] }
    assert_equal Mcp::Registry.tools_for(Mcp::Registry::BASE_GROUPS).size, tools.size
    assert_includes tools, "start_session"
    assert_includes tools, "action_health"
    assert_includes tools, "wake_me_up_later"
  end

  # Least privilege over the endpoint every session's `zimmer` entry points at:
  # an opt-in group has to be named in the URL before its tools exist for that
  # connection. The gate decision ledger is the one that matters — a session
  # holding the full server must not be able to write the gates' own ratings.
  test "tools/list omits opt-in groups until the connection names one" do
    unscoped = rpc("tools/list")["result"]["tools"].map { |t| t["name"] }

    refute_includes unscoped, "record_gate_decision"
    refute_includes unscoped, "search_gate_decisions"
    refute_includes unscoped, "get_gate_decision_feedback"

    scoped = rpc("tools/list", path: "/mcp?tool_groups=gate_decisions")["result"]["tools"].map { |t| t["name"] }

    assert_equal %w[search_gate_decisions get_gate_decision_feedback record_gate_decision].sort, scoped.sort

    readonly = rpc("tools/list", path: "/mcp?tool_groups=gate_decisions_readonly")["result"]["tools"].map { |t| t["name"] }

    assert_equal %w[search_gate_decisions get_gate_decision_feedback].sort, readonly.sort
  end

  test "the work backlog's writes exist only on a connection that names work_backlog" do
    unscoped = rpc("tools/list")["result"]["tools"].map { |t| t["name"] }
    refute_includes unscoped, "append_work_backlog_item"
    refute_includes unscoped, "pull_work_backlog_items"
    refute_includes unscoped, "get_work_backlog"

    sessions_only = rpc("tools/list", path: "/mcp?tool_groups=sessions")["result"]["tools"].map { |t| t["name"] }
    refute_includes sessions_only, "append_work_backlog_item"

    call = rpc("tools/call", { "name" => "append_work_backlog_item", "arguments" => {} }, path: "/mcp?tool_groups=sessions")
    assert_equal(-32602, call["error"]["code"], "a sessions-scoped connection cannot call the append tool")

    scoped = rpc("tools/list", path: "/mcp?tool_groups=work_backlog")["result"]["tools"].map { |t| t["name"] }
    assert_equal %w[get_work_backlog append_work_backlog_item pull_work_backlog_items].sort, scoped.sort

    readonly = rpc("tools/list", path: "/mcp?tool_groups=work_backlog_readonly")["result"]["tools"].map { |t| t["name"] }
    assert_equal [ "get_work_backlog" ], readonly

    # No tool on ANY connection pins, hand-places, removes by judgement or
    # promotes an item — those are the REST controller's, on purpose.
    everything = Mcp::Registry::VALID_GROUPS.join(",")
    all_tools = rpc("tools/list", path: "/mcp?tool_groups=#{everything}")["result"]["tools"].map { |t| t["name"] }
    assert_empty all_tools.grep(/pin|place|remove|start_now|promote/)
  end

  test "the append tool stamps the writing session from the connection, not the body" do
    writer = sessions(:running)
    args = { "key" => "zimmer#5", "issue_url" => "https://github.com/tadasant/zimmer/issues/5", "repo" => "tadasant/zimmer",
             "surface" => "zimmer", "title" => "t", "kind" => "bug", "scope_direction" => "convergent", "estimated_cost" => "small" }

    body = rpc("tools/call", { "name" => "append_work_backlog_item", "arguments" => args },
               path: "/mcp?tool_groups=work_backlog&session_id=#{writer.id}")

    assert_nil body["error"], body.inspect
    assert_equal writer.id, WorkBacklogItem.find_by!(key: "zimmer#5").writing_session_id
  end

  test "tools/list is scoped by tool_groups" do
    tools = rpc("tools/list", path: "/mcp?tool_groups=self_session")["result"]["tools"].map { |t| t["name"] }

    assert_equal %w[get_session get_session_provenance get_configs action_session send_push_notification
                    wake_me_up_later wake_me_up_when_session_changes_state].sort, tools.sort
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

  test "get_configs tool call exposes runtime model discovery" do
    body = rpc("tools/call", { "name" => "get_configs", "arguments" => {} })
    text = body["result"]["content"].first["text"]

    assert_response :success
    assert_includes text, "## Runtime Models"
    assert_includes text, "`fable`"
    assert_includes text, "`gpt-5.6-terra` (default, requires OAuth)"
  end

  test "tools/call surfaces a tool error as an error result, not a protocol error" do
    body = rpc("tools/call", { "name" => "get_session", "arguments" => { "id" => "999999999" } })

    assert body["result"]["isError"], "expected isError for a missing session"
    assert_match(/not found/i, body["result"]["content"].first["text"])
    assert_nil body["error"]
  end

  test "tools/call on a tool outside the enabled groups is rejected" do
    body = rpc("tools/call", { "name" => "start_session", "arguments" => {} }, path: "/mcp?tool_groups=self_session")

    assert_equal(-32602, body["error"]["code"])
    assert_match(/Tool not found/, body["error"]["data"].to_s)
  end

  # JSON-RPC batching was removed from the MCP spec (2025-11-25); one message per POST.
  test "a batched body is rejected as an invalid request" do
    post "/mcp", params: [
      { jsonrpc: "2.0", id: 1, method: "ping" },
      { jsonrpc: "2.0", id: 2, method: "tools/list" }
    ].to_json, headers: @headers

    assert_equal(-32600, JSON.parse(response.body)["error"]["code"])
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
