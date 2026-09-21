# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A Zimmer plugin's MCP endpoint, driven the way an MCP client (or a gateway
# proxying one) drives it: JSON-RPC over POST /mcp/external_app.
class ExternalAppMcpControllerTest < ActionDispatch::IntegrationTest
  include ExternalAppTestHelpers

  setup do
    @full_api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @full_api_key
    @trigger = triggers(:enabled_slack_trigger)
    @trigger.update!(prompt_template: "Vet the listing {{text}}", max_sessions_per_minute: 30)
    @other_trigger = triggers(:disabled_slack_trigger)
    @app, @token = create_plugin_with_key(triggers: [ @trigger ])
    @headers = {
      "Authorization" => "Bearer #{@token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  def rpc(method, params = {}, path: "/mcp/external_app", headers: @headers)
    post path, params: { jsonrpc: "2.0", id: 1, method: method, params: params }.to_json, headers: headers
    response.body.presence && JSON.parse(response.body)
  end

  def call_tool(name, arguments = {}, **options)
    rpc("tools/call", { name: name, arguments: arguments }, **options)
  end

  def tool_json(body)
    JSON.parse(body.dig("result", "content", 0, "text"))
  end

  test "initialize names the plugin and the connection lists exactly two tools" do
    body = rpc("initialize", { "protocolVersion" => "2025-03-26", "capabilities" => {}, "clientInfo" => { "name" => "strad", "version" => "1" } })
    assert_response :success
    assert_includes body["result"]["instructions"], "Housing search"

    body = rpc("tools/list")
    assert_equal %w[invoke_trigger list_triggers], body["result"]["tools"].map { |t| t["name"] }.sort
  end

  test "X-API-Key works as well as a bearer token" do
    body = rpc("tools/list", headers: @headers.except("Authorization").merge("X-API-Key" => @token))
    assert_response :success
    assert_equal 2, body["result"]["tools"].size
  end

  test "tool_groups in the URL change nothing" do
    %w[sessions triggers self_session external_apps settings].each do |groups|
      body = rpc("tools/list", path: "/mcp/external_app?tool_groups=#{groups}&allowed_agent_roots=zimmer")
      assert_equal %w[invoke_trigger list_triggers], body["result"]["tools"].map { |t| t["name"] }.sort, groups
    end
  end

  test "a tool the connection does not have cannot be called, whatever the URL" do
    stub_trigger_session_creation

    assert_no_difference("Session.count") do
      body = call_tool("start_session", { agent_root: "zimmer", prompt: "hi" }, path: "/mcp/external_app?tool_groups=sessions")
      assert body["error"] || body.dig("result", "isError"), "start_session answered on a plugin connection: #{body}"

      body = call_tool("action_trigger", { action: "invoke", id: @other_trigger.id }, path: "/mcp/external_app?tool_groups=triggers")
      assert body["error"] || body.dig("result", "isError"), "action_trigger answered on a plugin connection: #{body}"

      body = call_tool("get_session", { session_id: Session.first.id }, path: "/mcp/external_app?tool_groups=self_session")
      assert body["error"] || body.dig("result", "isError"), "get_session answered on a plugin connection: #{body}"
    end
  end

  test "list_triggers returns the allowlist" do
    json = tool_json(call_tool("list_triggers"))

    assert_equal "Housing search", json["external_app"]["name"]
    assert_equal [ { "id" => @trigger.id, "name" => @trigger.name, "variables" => [ "text" ], "max_sessions_per_minute" => 30 } ],
                 json["triggers"]
  end

  test "invoke_trigger fires an allowlisted trigger and returns the session" do
    stub_trigger_session_creation

    body = nil
    assert_difference("Session.count", 1) do
      body = call_tool("invoke_trigger", { trigger_id: @trigger.id, variables: { text: "listing-7" } })
    end

    assert_not body["result"]["isError"]
    json = tool_json(body)
    session = Session.order(:id).last
    assert_equal "fired", json["outcome"]
    assert_equal session.id, json["session"]["id"]
    assert_equal "http://www.example.com/sessions/#{session.id}", json["session"]["url"]
    assert_equal "Vet the listing listing-7", session.prompt
    assert_equal @app.id, session.metadata["external_app_id"]
  end

  test "invoke_trigger on a trigger off the allowlist is a tool error and fires nothing" do
    body = nil
    assert_no_difference("Session.count") do
      body = call_tool("invoke_trigger", { trigger_id: @other_trigger.id })
    end

    assert body["result"]["isError"]
    assert_equal "not_found", tool_json(body)["outcome"]
  end

  test "a disabled plugin, a revoked key and a full-API key are refused before any tool runs" do
    rpc("tools/list", headers: @headers.merge("Authorization" => "Bearer #{@full_api_key}"))
    assert_response :unauthorized

    @app.update!(enabled: false)
    rpc("tools/list")
    assert_response :forbidden

    @app.update!(enabled: true)
    @app.api_keys.each(&:revoke!)
    rpc("tools/list")
    assert_response :unauthorized
  end

  test "the plugin tools are not reachable from /mcp with a full-API key" do
    Mcp::Registry::VALID_GROUPS.each do |group|
      names = Mcp::Registry.tools_for([ group ]).map(&:tool_name)
      assert_not_includes names, "invoke_trigger", group
      assert_not_includes names, "list_triggers", group
    end

    body = call_tool("invoke_trigger", { trigger_id: @trigger.id }, path: "/mcp",
                     headers: @headers.merge("Authorization" => "Bearer #{@full_api_key}"))
    assert body["error"] || body.dig("result", "isError")
  end

  test "the plugin tools refuse to run on a context that is not a plugin's" do
    result = Mcp::Tools::ExternalAppInvokeTrigger.call(server_context: Mcp::Context.new(tool_groups: "triggers"), trigger_id: @trigger.id)
    assert result.error?
    assert_includes result.content.first[:text], "only available on a Zimmer plugin's connection"
  end
end
