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
    # promotes an item — those are the REST controller's and the browser's, on
    # purpose. The browser half is WorkBacklogPromotionsController,
    # WorkBacklogPinsController and WorkBacklogRemovalsController.
    everything = Mcp::Registry::VALID_GROUPS.join(",")
    all_tools = rpc("tools/list", path: "/mcp?tool_groups=#{everything}")["result"]["tools"].map { |t| t["name"] }
    assert_empty all_tools.grep(/pin|place|remove|start_now|promote/)
  end

  # The Settings page over the wire. The write changes what every later session
  # is created under, so it is offered only to a connection that names
  # `settings`: the unscoped surface and the self_session server injected into
  # every session cannot even call it.
  test "the settings tools exist only on a connection that names settings, and round-trip through POST /mcp" do
    AppSetting.delete_all
    tool_names = ->(path) { rpc("tools/list", path: path)["result"]["tools"].map { |t| t["name"] } }
    text = ->(body) { body["result"]["content"].first["text"] }

    refute_includes tool_names.call("/mcp"), "get_app_settings"
    refute_includes tool_names.call("/mcp"), "action_app_settings"
    refute_includes tool_names.call("/mcp?tool_groups=self_session"), "action_app_settings"

    denied = rpc("tools/call", { "name" => "action_app_settings",
                                 "arguments" => { "action" => "set_experimental_setting", "setting" => "mcp_tool_search", "enabled" => false } })
    assert_equal(-32602, denied["error"]["code"], "the unscoped surface cannot call the write")
    assert AppSetting.mcp_tool_search_enabled?, "a refused call wrote anyway"

    assert_equal [ "get_app_settings" ], tool_names.call("/mcp?tool_groups=settings_readonly")

    scoped = "/mcp?tool_groups=settings"
    assert_equal %w[get_app_settings action_app_settings], tool_names.call(scoped)

    before = rpc("tools/call", { "name" => "get_app_settings", "arguments" => {} }, path: scoped)
    assert_includes text.call(before), "**Runtime:** `claude_code` (Claude Code) — shipped default, no override set"

    set = rpc("tools/call", { "name" => "action_app_settings",
                              "arguments" => { "action" => "set_session_defaults", "runtime" => "codex", "model" => "gpt-5.5" } }, path: scoped)
    refute set["result"]["isError"], text.call(set)
    assert_includes text.call(set), "**After:** runtime `codex` (override), model `gpt-5.5` (override)"

    toggled = rpc("tools/call", { "name" => "action_app_settings",
                                  "arguments" => { "action" => "set_experimental_setting", "setting" => "mcp_tool_search", "enabled" => false } }, path: scoped)
    refute toggled["result"]["isError"], text.call(toggled)
    refute AppSetting.mcp_tool_search_enabled?

    refused = rpc("tools/call", { "name" => "action_app_settings",
                                  "arguments" => { "action" => "set_session_defaults", "runtime" => "claude_code", "model" => "gpt-5.5" } }, path: scoped)
    assert refused["result"]["isError"], "an invalid pair came back as a success"
    assert_match(/gpt-5.5 is not available for Claude Code/, text.call(refused))

    after = text.call(rpc("tools/call", { "name" => "get_app_settings", "arguments" => {} }, path: scoped))
    assert_includes after, "**Runtime:** `codex` (Codex) — operator override"
    assert_includes after, "**Model:** `gpt-5.5` — operator override"
    assert_match(/`mcp_tool_search`\): \*\*off\*\* — operator override/, after)
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

  # The Outcomes pair, end to end through the endpoint: which connections list
  # each tool, and that a call through JSON-RPC reaches the same services the
  # web UI's buttons do.
  test "get_outcome_analysis is on the session surfaces, and action_outcome_analysis only on the opt-in group" do
    lists = {
      "" => rpc("tools/list"),
      "sessions" => rpc("tools/list", path: "/mcp?tool_groups=sessions"),
      "sessions_readonly" => rpc("tools/list", path: "/mcp?tool_groups=sessions_readonly"),
      "self_session" => rpc("tools/list", path: "/mcp?tool_groups=self_session"),
      "sessions_readonly,outcome_analyses" => rpc("tools/list", path: "/mcp?tool_groups=sessions_readonly,outcome_analyses")
    }.transform_values { |body| body["result"]["tools"].map { |t| t["name"] } }

    %w[sessions sessions_readonly].push("").each { |groups| assert_includes lists[groups], "get_outcome_analysis" }
    [ "", "sessions", "sessions_readonly", "self_session" ].each do |groups|
      refute_includes lists[groups], "action_outcome_analysis", "#{groups.presence || 'unscoped'} must not start analyses"
    end
    refute_includes lists["self_session"], "get_outcome_analysis"
    assert_includes lists["sessions_readonly,outcome_analyses"], "action_outcome_analysis"
    assert_includes lists["sessions_readonly,outcome_analyses"], "get_outcome_analysis"

    call = rpc("tools/call", { "name" => "action_outcome_analysis", "arguments" => { "action" => "cancel_batch", "batch_id" => 1 } },
               path: "/mcp?tool_groups=sessions")
    assert_equal(-32602, call["error"]["code"], "a sessions-scoped connection cannot call the write")
  end

  test "get_outcome_analysis reads a saved analysis tree through the endpoint" do
    session = sessions(:archived)
    OutcomeAnalyses::Save.call(session: session, root: {
      "id" => "S0", "trigger" => { "kind" => "New", "source" => "user" }, "goal" => { "text" => "Ship", "kind" => "Action" },
      "outcome" => { "kind" => "Failure", "explanation" => "It did not ship." }, "meta" => {}, "children" => []
    })

    body = rpc("tools/call", { "name" => "get_outcome_analysis", "arguments" => { "session_id" => session.id } },
               path: "/mcp?tool_groups=sessions_readonly")

    refute body["result"]["isError"], body.inspect
    result = JSON.parse(body["result"]["content"].first["text"])
    assert_equal "Failure", result["analysis"]["root_outcome"]
    assert_equal "S0", result["analysis"]["root"]["id"]
    assert_equal [ "S0" ], result["failed_segments"].map { |f| f["id"] }

    stats = rpc("tools/call", { "name" => "get_outcome_analysis", "arguments" => { "view" => "stats", "group_by" => "agent_root" } },
                path: "/mcp?tool_groups=sessions_readonly")
    refute stats["result"]["isError"], stats.inspect
    assert_operator JSON.parse(stats["result"]["content"].first["text"])["totals"]["failures"], :>=, 1
  end

  test "action_outcome_analysis starts a batch as the calling session and holds it to the agent cap" do
    caller_session = sessions(:running)
    Array.new(2) do |i|
      Session.create!(title: "Target #{i}", prompt: "x", git_root: "https://github.com/tadasant/zimmer.git",
                      status: :archived, archived_at: 1.day.ago, metadata: { "agent_root_key" => "zimmer" })
    end
    path = "/mcp?tool_groups=sessions_readonly,outcome_analyses&session_id=#{caller_session.id}"
    args = { "action" => "analyze_all", "agent_root" => "zimmer", "expected_count" => 2 }

    over = rpc("tools/call", { "name" => "action_outcome_analysis",
                               "arguments" => args.merge("concurrency" => OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY + 1) }, path: path)
    assert over["result"]["isError"], over.inspect
    assert_match(/at most #{OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY} analyses at a time/, over["result"]["content"].first["text"])
    assert_equal 0, OutcomeAnalysisBatch.count

    body = rpc("tools/call", { "name" => "action_outcome_analysis", "arguments" => args.merge("concurrency" => 2) }, path: path)
    refute body["result"]["isError"], body.inspect
    batch = OutcomeAnalysisBatch.sole
    assert_equal [ "mcp", caller_session.id, 2, 2 ], [ batch.started_via, batch.started_by_session_id, batch.concurrency, batch.total_count ]

    again = rpc("tools/call", { "name" => "action_outcome_analysis", "arguments" => args }, path: path)
    assert again["result"]["isError"], "a second MCP batch while the first runs is refused"
    assert_match(/Batch ##{batch.id}, started over MCP, is still running/, again["result"]["content"].first["text"])

    stop = rpc("tools/call", { "name" => "action_outcome_analysis", "arguments" => { "action" => "cancel_batch", "batch_id" => batch.id } },
               path: path)
    refute stop["result"]["isError"], stop.inspect
    assert_equal OutcomeAnalysisBatch::CANCELED, batch.reload.status
  end

  test "tools/list is scoped by tool_groups" do
    tools = rpc("tools/list", path: "/mcp?tool_groups=self_session")["result"]["tools"].map { |t| t["name"] }

    assert_equal %w[get_session get_session_provenance get_configs action_session send_push_notification
                    wake_me_up_later wake_me_up_when_session_changes_state get_costs].sort, tools.sort
    refute_includes tools, "start_session"
  end

  # Same tool name, narrower contract. A session's self-session surface carries
  # the self-scoped get_costs, so what `tools/list` advertises there must be the
  # session-only schema rather than the fleet tool's.
  test "the self_session get_costs advertises the self-scoped schema, not the fleet one" do
    schema = rpc("tools/list", path: "/mcp?tool_groups=self_session")["result"]["tools"]
      .find { |t| t["name"] == "get_costs" }["inputSchema"]

    assert_equal %w[days from to session_id].sort, schema["properties"].keys.sort
    refute_includes schema["properties"].keys, "agent_root"

    fleet = rpc("tools/list", path: "/mcp?tool_groups=health")["result"]["tools"]
      .find { |t| t["name"] == "get_costs" }["inputSchema"]

    assert_includes fleet["properties"].keys, "agent_root"
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
