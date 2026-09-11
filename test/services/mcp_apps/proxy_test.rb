# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpApps::ProxyTest < ActiveSupport::TestCase
  TOOLS = [
    { "name" => "open_panel", "_meta" => { "ui" => { "resourceUri" => "ui://demo/panel.html" } } },
    { "name" => "roll_dice", "_meta" => { "ui" => { "visibility" => [ "app" ] } } },
    { "name" => "delete_everything" }
  ].freeze

  setup do
    @session = Session.create!(
      agent_runtime: "claude_code", prompt: "x", mcp_servers: [ "notion" ],
      git_root: "https://github.com/test/repo.git", branch: "main"
    )
    AppSetting.create!(mcp_apps_enabled: true, mcp_apps_allowed_servers: [ "notion" ])

    @client = mock("client")
    @client.stubs(:tools_list).returns(TOOLS)
    @connection = McpApps::ServerConnection.new(@session, "notion")
    @connection.stubs(:client).returns(@client)
    @proxy = McpApps::Proxy.new(@connection)
  end

  test "forwards a tool the server marked visibility app" do
    @client.expects(:call_tool).with("roll_dice", { "sides" => 6 }).returns({ "content" => [] })

    result = @proxy.call("tools/call", { "name" => "roll_dice", "arguments" => { "sides" => 6 } })

    assert result.ok?
    assert_equal({ "content" => [] }, result.result)
  end

  test "refuses a tool the server did not mark app-callable" do
    @client.expects(:call_tool).never

    result = @proxy.call("tools/call", { "name" => "delete_everything" })

    refute result.ok?
    assert_equal McpApps::Proxy::METHOD_NOT_FOUND, result.code
    assert_match "visibility", result.message
  end

  test "refuses the very tool whose view this is, when it is model-only" do
    # `open_panel` declares the view but not `visibility: ["app"]`, so the view
    # cannot re-invoke the call that created it.
    @client.expects(:call_tool).never

    refute @proxy.call("tools/call", { "name" => "open_panel" }).ok?
  end

  test "refuses a tool the server does not have at all" do
    refute @proxy.call("tools/call", { "name" => "made_up" }).ok?
  end

  test "forwards resources/read" do
    @client.expects(:resources_read).with("ui://demo/panel.html").returns({ "contents" => [] })

    assert @proxy.call("resources/read", { "uri" => "ui://demo/panel.html" }).ok?
  end

  test "forwards nothing else" do
    %w[tools/list resources/list prompts/get completion/complete initialize elicitation/create].each do |method|
      result = @proxy.call(method, {})

      refute result.ok?, "#{method} must not be forwarded"
      assert_equal McpApps::Proxy::METHOD_NOT_FOUND, result.code
    end
  end

  test "bad params are rejected before the server is touched" do
    @client.expects(:call_tool).never
    @client.expects(:resources_read).never

    assert_equal McpApps::Proxy::INVALID_PARAMS, @proxy.call("tools/call", {}).code
    assert_equal McpApps::Proxy::INVALID_PARAMS, @proxy.call("resources/read", {}).code
    assert_equal McpApps::Proxy::INVALID_PARAMS,
      @proxy.call("resources/read", { "uri" => "u" * 5000 }).code
  end

  test "a server error is reported with the server's own code, not as a crash" do
    @client.expects(:call_tool).raises(McpApps::Client::RpcError.new("boom", code: -32000))

    result = @proxy.call("tools/call", { "name" => "roll_dice" })

    refute result.ok?
    assert_equal(-32000, result.code)
  end

  test "an unreachable server is an error result rather than an exception" do
    @client.expects(:call_tool).raises(McpApps::Client::Error, "could not reach MCP server")

    result = @proxy.call("tools/call", { "name" => "roll_dice" })

    refute result.ok?
    assert_equal McpApps::Proxy::INTERNAL_ERROR, result.code
  end
end
