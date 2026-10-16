# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversations::ToolBridgeTest < ActiveSupport::TestCase
  setup do
    @conversation = create_live_conversation(mode: "voice")
    @bridge = LiveConversations::ToolBridge.new(@conversation)
  end

  test "a conversation with the zimmer server gets the gateway, not one function per Zimmer tool" do
    names = @bridge.functions.map(&:name)

    assert_equal %w[zimmer describe_zimmer_tool list_mcp_servers enable_mcp_server disable_mcp_server get_live_settings update_live_settings], names
    gateway = @bridge.functions.first
    assert_includes gateway.parameters[:properties][:tool][:enum], "quick_router"
    assert_includes gateway.parameters[:properties][:tool][:enum], "get_system_health"
    assert_match(/- start_session\(/, gateway.description)
    # The whole point of the gateway: the full surface is ~200 KB, this is not.
    assert_operator JSON.generate(@bridge.realtime_tools).bytesize, :<, 20_000
  end

  test "a scoped Zimmer server narrows the gateway to the groups its URL names" do
    @conversation.update!(mcp_servers: [ "zimmer-sessions" ])
    tools = LiveConversations::ToolBridge.new(@conversation).functions.first.parameters[:properties][:tool][:enum]

    assert_includes tools, "start_session"
    assert_not_includes tools, "get_system_health"
  end

  test "no Zimmer server means no gateway, and calling it says how to get one" do
    @conversation.update!(mcp_servers: [])
    bridge = LiveConversations::ToolBridge.new(@conversation)

    assert_not_includes bridge.functions.map(&:name), "zimmer"
    result = bridge.execute("zimmer", { tool: "get_system_health" }.to_json, call_id: "c1")
    assert result.error
    assert_match(/enable_mcp_server with name "zimmer"/, result.output)
  end

  test "the realtime and chat shapes carry the same functions" do
    assert_equal @bridge.realtime_tools.map { |t| t[:name] }, @bridge.chat_tools.map { |t| t[:function][:name] }
    assert_equal "function", @bridge.realtime_tools.first[:type]
    assert @bridge.realtime_tools.first.key?(:parameters)
  end

  test "a zimmer call runs the tool in-process and records a tool turn" do
    result = @bridge.execute("zimmer", { tool: "quick_search_sessions", arguments: {} }.to_json, call_id: "call_1")

    assert_not result.error, result.output
    turn = @conversation.turns.last
    assert turn.tool?
    assert_equal "call_1", turn.call_id
    assert_equal "zimmer", turn.tool_name
    assert_equal({ "tool" => "quick_search_sessions", "arguments" => {} }, turn.tool_arguments)
    assert_equal result.output, turn.model_output
  end

  test "delegating through the gateway starts a real background session" do
    AgentSessionJob.stubs(:enqueue_new_session).returns(stub(job_id: "job-1", provider_job_id: "job-1"))
    arguments = { tool: "start_session", arguments: { agent_root: "zimmer", prompt: "Look into the flaky poller test", title: "Flaky poller" } }

    assert_difference -> { Session.count }, 1 do
      result = @bridge.execute("zimmer", arguments.to_json, call_id: "call_delegate")
      assert_not result.error, result.output
    end
    assert_equal "Look into the flaky poller test", Session.order(:id).last.prompt
  end

  test "a Zimmer tool's own error comes back as an error result" do
    result = @bridge.execute("zimmer", { tool: "get_session", arguments: { id: "999999999" } }.to_json, call_id: "c2")

    assert result.error
    assert_match(/not found/i, result.output)
  end

  test "gateway calls meet the same argument checks POST /mcp applies before a tool runs" do
    Mcp::Tools::QuickRouter.any_instance.expects(:call).never

    missing = @bridge.execute("zimmer", { tool: "quick_router", arguments: {} }.to_json, call_id: "c_missing")
    assert missing.error
    assert_match(/Missing required arguments: prompt/, missing.output)

    wrong_type = @bridge.execute("zimmer", { tool: "get_session", arguments: { id: "1", include_transcript: "yes please" } }.to_json, call_id: "c_type")
    assert wrong_type.error
  end

  test "the live agent's gateway carries no live-conversation tools: they are an opt-in group" do
    tools = @bridge.functions.first.parameters[:properties][:tool][:enum]

    assert_includes tools, "start_session"
    assert_not_includes tools, "get_live_conversations"
    assert_not_includes tools, "action_live_conversation"
  end

  test "a zimmer entry that names live_conversations still cannot end or replace its own conversation" do
    scoped = ServersConfig::Server.new("zimmer", { "type" => "http", "url" => "https://zimmer.example.com/mcp?tool_groups=live_conversations" })
    ServersConfig.stubs(:find).with("zimmer").returns(scoped)

    tools = LiveConversations::ToolBridge.new(@conversation).functions.first.parameters[:properties][:tool][:enum]

    assert_includes tools, "get_live_conversations"
    assert_not_includes tools, "action_live_conversation"
  end

  test "describe_zimmer_tool returns the full description and schema" do
    result = @bridge.execute("describe_zimmer_tool", { tool: "quick_router" }.to_json, call_id: "c3")

    assert_not result.error
    assert_includes result.output, "Arguments schema:"
    assert_includes result.output, "prompt"
  end

  test "bad arguments and unknown functions are errors the model can read, not exceptions" do
    assert_match(/not valid JSON/, @bridge.execute("zimmer", "{nope", call_id: "c4").output)
    assert_match(/No function named nope/, @bridge.execute("nope", "{}", call_id: "c5").output)
    assert_match(/no tool named "nope"/, @bridge.execute("zimmer", { tool: "nope" }.to_json, call_id: "c6").output)
    assert_equal 3, @conversation.turns.where(tool_error: true).count
  end

  test "an unexpected failure inside a tool is returned to the model, not raised" do
    Mcp::Tools::GetSystemHealth.any_instance.stubs(:call).raises(RuntimeError, "boom")

    result = @bridge.execute("zimmer", { tool: "get_system_health" }.to_json, call_id: "c7")
    assert result.error
    assert_match(/boom/, result.output)
  end

  test "list_mcp_servers lists the catalog with what this conversation has enabled" do
    listing = JSON.parse(@bridge.execute("list_mcp_servers", "{}", call_id: "c8").output)
    zimmer = listing.find { |entry| entry["name"] == "zimmer" }

    assert zimmer["enabled"]
    assert listing.any? { |entry| entry["name"] == "context7" && entry["enabled"] == false }
  end

  test "self-enable: enabling a catalog server lists its tools once and exposes them as direct functions" do
    stub_clock_server

    result = @bridge.execute("enable_mcp_server", { name: "test-clock" }.to_json, call_id: "c9")

    assert_not result.error, result.output
    assert result.tools_changed
    assert_match(/test-clock__current_time, test-clock__env_names/, result.output)
    @conversation.reload
    assert_equal %w[zimmer test-clock], @conversation.mcp_servers
    assert_equal %w[current_time env_names], @conversation.mcp_tool_cache["test-clock"].map { |t| t["name"] }

    bridge = LiveConversations::ToolBridge.new(@conversation)
    assert_includes bridge.functions.map(&:name), "test-clock__current_time"

    call = bridge.execute("test-clock__current_time", "{}", call_id: "c10")
    assert_not call.error, call.output
    assert_equal "It is noon. hello", call.output
  end

  test "a stdio server Zimmer spawns gets its catalog env and a few basics, never the Rails environment" do
    stub_clock_server
    @bridge.execute("enable_mcp_server", { name: "test-clock" }.to_json, call_id: "c11")
    ENV["LIVE_TEST_LEAK_CHECK"] = "should-not-reach-the-server"

    names = LiveConversations::ToolBridge.new(@conversation.reload).execute("test-clock__env_names", "{}", call_id: "c12").output.split(",")

    assert_includes names, "CLOCK_GREETING"
    assert_includes names, "PATH"
    assert_not_includes names, "LIVE_TEST_LEAK_CHECK"
    assert_not_includes names, "DATABASE_PORT"
    assert_empty names - (%w[CLOCK_GREETING] + LiveConversations::CatalogServer::INHERITED_ENV)
  ensure
    ENV.delete("LIVE_TEST_LEAK_CHECK")
  end

  test "disabling a server removes its functions" do
    stub_clock_server
    @bridge.execute("enable_mcp_server", { name: "test-clock" }.to_json, call_id: "c13")

    result = LiveConversations::ToolBridge.new(@conversation.reload).execute("disable_mcp_server", { name: "test-clock" }.to_json, call_id: "c14")

    assert result.tools_changed
    assert_equal %w[zimmer], @conversation.reload.mcp_servers
    assert_empty @conversation.mcp_tool_cache
    assert_not_includes LiveConversations::ToolBridge.new(@conversation).functions.map(&:name), "test-clock__current_time"
  end

  test "enabling a server that is not in the catalog, or cannot start, is a readable error" do
    result = @bridge.execute("enable_mcp_server", { name: "no-such-server" }.to_json, call_id: "c15")
    assert result.error
    assert_match(/No MCP server named "no-such-server"/, result.output)

    broken = ServersConfig::Server.new("broken", { "type" => "stdio", "command" => "/nonexistent/binary" })
    ServersConfig.stubs(:find).with("broken").returns(broken)
    result = @bridge.execute("enable_mcp_server", { name: "broken" }.to_json, call_id: "c16")
    assert result.error
    assert_match(/broken:/, result.output)
    assert_equal %w[zimmer], @conversation.reload.mcp_servers
  end

  test "enabling one of Zimmer's own servers widens the gateway instead of adding direct tools" do
    @conversation.update!(mcp_servers: [ "zimmer-sessions" ])
    result = LiveConversations::ToolBridge.new(@conversation).execute("enable_mcp_server", { name: "zimmer-self-session" }.to_json, call_id: "c17")

    assert_not result.error, result.output
    assert_match(/through the zimmer function/, result.output)
    assert_empty @conversation.reload.mcp_tool_cache
  end

  test "the live model reads and changes its own settings, and the change is recorded as its own" do
    listing = @bridge.execute("get_live_settings", "{}", call_id: "c1")
    assert_match(/voice_speed = 1\.0 \(default\)/, listing.output)

    result = @bridge.execute("update_live_settings", JSON.generate(voice_speed: 1.3, append_guidance: "Talk faster by default."), call_id: "c2")

    assert_not result.error
    assert result.session_changed
    assert_match(/Speaking speed: default \(1\.0\) → 1\.3/, result.output)
    assert_in_delta 1.3, LiveSetting.current.voice_speed
    change = LiveSettingChange.sole
    assert_equal "agent", change.actor_kind
    assert_equal "live conversation ##{@conversation.id}", change.actor
    assert_equal @conversation, change.live_conversation
  end

  test "a bad settings write is refused as a tool error and changes nothing" do
    result = @bridge.execute("update_live_settings", JSON.generate(voice_model: "gpt-9", voice_speed: 1.2), call_id: "c3")

    assert result.error
    assert_not result.session_changed
    assert_match(/Nothing changed/, result.output)
    assert_not LiveSetting.exists?
  end

  test "a model or voice change applies from the next call, so it does not ask for a session.update" do
    result = @bridge.execute("update_live_settings", JSON.generate(voice_model: "gpt-realtime-2.1"), call_id: "c4")

    assert_not result.session_changed
    assert_match(/from the next call/, result.output)
  end
end
