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

    assert_equal %w[zimmer describe_zimmer_tool list_mcp_servers enable_mcp_server disable_mcp_server get_live_settings update_live_settings list_live_conversations switch_live_conversation], names
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

  test "the realtime and chat shapes carry the same functions, and only a call can hang up" do
    assert_equal @bridge.realtime_tools.map { |t| t[:name] }, @bridge.chat_tools.map { |t| t[:function][:name] } + [ "hang_up" ]
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

  test "a knob with no effect is answered as no effect, with the instruction to say so, never as a change" do
    result = @bridge.execute("update_live_settings", JSON.generate(voice_vad_threshold: 0.75, voice_vad_silence_duration_ms: 900), call_id: "n1")

    assert_not result.error
    assert result.output.start_with?("Saved, but this changes nothing on a call:"), result.output
    assert_no_match(/\AChanged:/, result.output)
    assert_match(/have no effect under Semantic turn detection/, result.output)
    assert_match(/Tell the person this out loud\. Do not say the setting was changed/, result.output)
    assert_in_delta 0.75, LiveSetting.current.voice_vad_threshold

    again = @bridge.execute("update_live_settings", JSON.generate(voice_vad_threshold: 0.75), call_id: "n2")
    assert_match(/\ANothing changed: those are already the settings\.\nThreshold \(silence\) has no effect/, again.output)
    assert_match(/Tell the person this out loud/, again.output)
  end

  test "a change that took is still answered as one, and a mixed one names what did nothing" do
    took = @bridge.execute("update_live_settings", JSON.generate(voice_vad_eagerness: "low"), call_id: "m1")
    assert took.output.start_with?("Changed:"), took.output
    assert_no_match(/no effect|out loud/, took.output)

    mixed = @bridge.execute("update_live_settings", JSON.generate(voice_speed: 1.2, voice_vad_threshold: 0.75), call_id: "m2")
    assert mixed.output.start_with?("Changed:"), mixed.output
    assert_match(/Threshold \(silence\) has no effect/, mixed.output)
    assert_match(/Say what changed, and say out loud which settings have no effect\./, mixed.output)
    assert_no_match(/Do not say the setting was changed/, mixed.output)

    switched = @bridge.execute("update_live_settings", JSON.generate(voice_turn_detection: "server_vad"), call_id: "m3")
    assert switched.output.start_with?("Changed:"), switched.output
    assert_match(/Eagerness \(semantic\) has no effect under Silence/, switched.output)
    assert_no_match(/Do not say the setting was changed/, switched.output)
  end

  test "reading the settings marks what the mode leaves unused" do
    listing = @bridge.execute("get_live_settings", "{}", call_id: "r1").output

    assert_match(/voice_vad_threshold = 0\.5 \(default\).*NO EFFECT now: used only under server_vad/, listing)
    assert_no_match(/voice_vad_eagerness = .*NO EFFECT/, listing)
  end

  test "the live model cannot change how much the app reports about its calls, nor reset it" do
    LiveConversations::SettingsUpdate.call({ "voice_telemetry" => "warn" }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    schema = @bridge.realtime_tools.find { |t| t[:name] == "update_live_settings" }
    assert_not schema.dig(:parameters, :properties).key?("voice_telemetry"), "not offered"

    result = @bridge.execute("update_live_settings", JSON.generate(voice_telemetry: "off"), call_id: "t1")
    assert result.error
    assert_match(/a person's to change/, result.output)

    @bridge.execute("update_live_settings", JSON.generate(reset_to_defaults: true), call_id: "t2")
    assert_equal "warn", LiveSetting.current.voice_telemetry, "a reset from the call keeps it"
  end

  test "the live model cannot change the voice output cap, nor reset a person's" do
    LiveConversations::SettingsUpdate.call({ "voice_max_output_tokens" => 2_048 }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    schema = @bridge.realtime_tools.find { |t| t[:name] == "update_live_settings" }
    assert_not schema.dig(:parameters, :properties).key?("voice_max_output_tokens"), "not offered"

    result = @bridge.execute("update_live_settings", JSON.generate(voice_max_output_tokens: 180), call_id: "t1")
    assert result.error
    assert_match(/a person's to change/, result.output)
    assert_equal 2_048, LiveSetting.current.voice_max_output_tokens

    @bridge.execute("update_live_settings", JSON.generate(reset_to_defaults: true), call_id: "t2")
    assert_equal 2_048, LiveSetting.current.voice_max_output_tokens, "a reset from the call keeps it"
  end

  # What a Realtime response cut off by the output cap relays: the arguments as
  # far as the model got, which is not JSON.
  test "a call whose arguments were cut off runs nothing and tells the model to try again or say so" do
    partial = %({"tool":"start_session","arguments":{"prompt":"Fix the)
    assert_no_difference -> { Session.count } do
      result = @bridge.execute("zimmer", partial, call_id: "cut1")

      assert result.error
      assert_match(/cut off/, result.output)
      assert_match(/Nothing ran/, result.output)
      assert_match(/tell the person/, result.output)
    end
  end

  test "a failed call reaches the logs, with its error and never its arguments" do
    lines = []
    Rails.logger.stubs(:warn).with { |message| lines << message; true }

    partial = %({"tool":"start_session","arguments":{"prompt":"Fix the)
    @bridge.execute("zimmer", partial, call_id: "cut2")

    line = lines.grep(/\[LiveConversations::ToolBridge\]/).sole
    assert_includes line, "function=zimmer"
    assert_includes line, "live_conversation=#{@conversation.id}"
    assert_includes line, "call_id=cut2"
    assert_includes line, "arguments_chars=#{partial.length}"
    assert_match(/cut off/, line)
    assert_not_includes line, "Fix the"
  end

  test "a catalog server's error stays off the log line, and an exception logs only its class" do
    lines = []
    Rails.logger.stubs(:warn).with { |message| lines << message; true }
    @conversation.update!(mcp_servers: [ "clock" ], mcp_tool_cache: { "clock" => [ { "name" => "now", "description" => "x", "input_schema" => { "type" => "object" } } ] })
    bridge = LiveConversations::ToolBridge.new(@conversation)
    server = stub(call_tool: [ "no such account: the words they said", true ])
    LiveConversations::CatalogServer.stubs(:find!).returns(server)

    assert bridge.execute("clock__now", "{}", call_id: "own").error
    server.stubs(:call_tool).raises(ArgumentError, "row with the words they said")
    assert bridge.execute("clock__now", "{}", call_id: "boom").error

    logged = lines.grep(/\[LiveConversations::ToolBridge\]/)
    assert_equal 2, logged.size
    assert_match(/failed: the server reported an error/, logged.first)
    assert_match(/failed: ArgumentError/, logged.second)
    assert_empty logged.grep(/the words they said/)
  end

  test "a call that worked writes no failure line" do
    lines = []
    Rails.logger.stubs(:warn).with { |message| lines << message; true }

    @bridge.execute("get_live_settings", "{}", call_id: "ok1")

    assert_empty lines.grep(/\[LiveConversations::ToolBridge\]/)
  end

  test "every settings change is shipped as a [LiveSettings] line naming who made it" do
    lines = []
    Rails.logger.stubs(:warn).with { |message| lines << message; true }
    @bridge.execute("update_live_settings", JSON.generate(voice_listening: "wake_word"), call_id: "t3")

    assert_includes lines, "[LiveSettings] agent: live conversation ##{@conversation.id} changed voice_listening: nil → \"wake_word\""
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

    @bridge.execute("update_live_settings", JSON.generate(voice_speed: 1.2), call_id: "c5")
    @bridge.execute("update_live_settings", JSON.generate(voice_speed: "default"), call_id: "c6")
    assert_nil LiveSetting.current.voice_speed, "one numeric setting can go back to its default"
    assert_equal "gpt-realtime-2.1", LiveSetting.current.voice_model
  end

  # --- Other conversations ---------------------------------------------------

  def ended_conversation(said: "Deploy the fix to staging when CI is green please")
    other = create_live_conversation(status: LiveConversation::ENDED, ended_at: 1.hour.ago, mode: "voice")
    other.turns.create!(role: "user", source: "spoken", content: said)
    other
  end

  def go_back_setup
    stub_live_root
    stub_live_key
  end

  test "the switch functions are there with no Zimmer server enabled" do
    @conversation.update!(mcp_servers: [])

    names = LiveConversations::ToolBridge.new(@conversation).functions.map(&:name)

    assert_includes names, "switch_live_conversation"
    assert_includes names, "list_live_conversations"
  end

  test "the list is three short names to say, and no URLs" do
    4.times { ended_conversation }

    output = @bridge.execute("list_live_conversations", "{}", call_id: "c1").output

    assert_equal 3, output.scan(/^- id /).size
    assert_includes output, "Deploy the fix to staging when…"
    assert_not_includes output, "http"
  end

  test "an empty list says so" do
    assert_match(/no earlier conversation/, @bridge.execute("list_live_conversations", "{}", call_id: "c1").output)
  end

  test "going back with no arguments moves to the last one and records the call on the thread left" do
    go_back_setup
    other = ended_conversation

    result = LiveConversations::ToolBridge.new(@conversation).execute("switch_live_conversation", "{}", call_id: "c1")

    assert_equal other, result.switched_to
    assert_not result.error
    assert_match(/Switched to "Deploy the fix/, result.output)
    assert_equal @conversation, result.turn.live_conversation
    assert @conversation.reload.ended?
    assert_equal other, LiveConversation.current
  end

  test "a refusal is the model's to say: nothing moves" do
    go_back_setup

    result = LiveConversations::ToolBridge.new(@conversation).execute("switch_live_conversation", "{}", call_id: "c1")

    assert result.error
    assert_nil result.switched_to
    assert_match(/no earlier conversation/, result.output)
    assert @conversation.reload.active?
  end

  test "switching to where it already is moves nothing" do
    go_back_setup

    result = LiveConversations::ToolBridge.new(@conversation).execute("switch_live_conversation", { "id" => @conversation.id }, call_id: "c1")

    assert_nil result.switched_to
    assert_not result.error
    assert_match(/already in/, result.output)
  end

  test "a client that cannot reattach is refused the switch, and its call stays on a live thread" do
    go_back_setup
    other = ended_conversation

    result = LiveConversations::ToolBridge.new(@conversation, can_reattach: false).execute("switch_live_conversation", "{}", call_id: "c1")

    assert result.error
    assert_match(/cannot move a call/, result.output)
    assert @conversation.reload.active?
    assert other.reload.ended?
  end

  test "the target's own servers are what a bridge built on it offers" do
    go_back_setup
    stub_clock_server
    other = create_live_conversation(status: LiveConversation::ENDED, ended_at: 1.hour.ago, mcp_servers: [ "zimmer", CLOCK_SERVER ],
                                     mcp_tool_cache: { CLOCK_SERVER => [ { "name" => "now", "description" => "The time.", "input_schema" => { "type" => "object" } } ] })
    other.turns.create!(role: "user", source: "typed", content: "What time is it now")
    assert_not_includes LiveConversations::ToolBridge.new(@conversation).functions.map(&:name), "test-clock__now"

    target = LiveConversations::ToolBridge.new(@conversation).execute("switch_live_conversation", "{}", call_id: "c1").switched_to

    assert_includes LiveConversations::ToolBridge.new(target).functions.map(&:name), "test-clock__now"
  end

  # --- Live Mode's defaults for a session search -----------------------------

  def search(arguments)
    @bridge.execute("zimmer", { tool: "quick_search_sessions", arguments: arguments }.to_json, call_id: "s#{SecureRandom.hex(3)}")
  end

  test "a search from Live Mode includes archived sessions and matches the words in any order" do
    target = Session.create!(title: "Diagnose failed Zimmer quokka voice session", prompt: "p", status: :archived,
                             git_root: "https://github.com/test/repo.git", agent_runtime: "claude_code")

    result = search(query: "diagnose quokka")

    assert_not result.error, result.output
    assert_includes result.output, "(ID: #{target.id})"
    assert_includes result.output, 'show_archived: true, match: "all_words"'
    # The turn records what the model asked for, not what Zimmer filled in.
    assert_equal({ "query" => "diagnose quokka" }, @conversation.turns.last.tool_arguments["arguments"])
  end

  test "an argument the model passed wins over Live Mode's default" do
    target = Session.create!(title: "Quokka archived explicit", prompt: "p", status: :archived,
                             git_root: "https://github.com/test/repo.git", agent_runtime: "claude_code")

    result = search(query: "Quokka archived explicit", show_archived: false)

    assert_not_includes result.output, "(ID: #{target.id})"
    assert_includes result.output, "1 more archived session(s) match"
    assert_includes result.output, 'Live Mode searched with match: "all_words" (its defaults for finding a session; pass it'
  end

  test "a listing and an id lookup get no defaults; a transcript scan gets show_archived but not match" do
    assert_not_includes search({}).output, "Live Mode searched with"
    assert_not_includes search(id: sessions(:router_child_running).id, query: "quokka").output, "Live Mode searched with"

    scan = search(query: "quokka", search_contents: true).output
    assert_includes scan, "Live Mode searched with show_archived: true (its defaults"
    assert_not_includes scan, "match:"
  end

  test "a status filter suppresses the archived default, an empty one does not" do
    assert_includes search(query: "quokka", status: "running").output, 'Live Mode searched with match: "all_words"'
    assert_includes search(query: "quokka", status: []).output, "show_archived: true, match"
  end

  test "hang_up is a voice call's, whatever servers are enabled, and says when to use it and when not" do
    @conversation.update!(mcp_servers: [])
    tool = LiveConversations::ToolBridge.new(@conversation).realtime_tools.find { |t| t[:name] == "hang_up" }

    assert tool
    assert_equal({ type: "object", properties: {} }, tool[:parameters])
    assert_match(/"stop listening"/, tool[:description])
    assert_match(/Never for those words quoted/, tool[:description])
    assert_match(/Do not ask them to confirm/, tool[:description])
    assert_match(/"Okay, hanging up"/, tool[:description])
    assert_not_includes LiveConversations::ToolBridge.new(@conversation).chat_tools.map { |t| t[:function][:name] }, "hang_up"
  end

  test "hanging up from a client that can is recorded and answers hung_up, and the conversation stays open" do
    result = LiveConversations::ToolBridge.new(@conversation, can_hang_up: true).execute("hang_up", "{}", call_id: "h1")

    assert result.hung_up
    assert_not result.error
    assert_match(/Hanging up/, result.output)
    assert_equal "hang_up", result.turn.tool_name
    assert @conversation.reload.active?
    assert @conversation.voice?
  end

  test "a client that cannot hang up is refused, and the model is told to send the person to End" do
    result = @bridge.execute("hang_up", "{}", call_id: "h1")

    assert_not result.hung_up
    assert result.error
    assert_match(/cannot hang up by voice.*tap End/, result.output)
  end

  test "no other function answers hung_up" do
    result = LiveConversations::ToolBridge.new(@conversation, can_hang_up: true).execute("list_live_conversations", "{}", call_id: "c1")

    assert_not result.hung_up
  end
end
