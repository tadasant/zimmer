# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversations::VoiceEngineTest < ActiveSupport::TestCase
  setup do
    @conversation = create_live_conversation(mode: "voice")
  end

  test "the default is OpenAI Realtime, so shipping the engines changes nothing" do
    stub_live_key
    stub_claude_key

    resolution = LiveConversations::VoiceEngine.resolve(@conversation, client_engines: %w[gpt_live_claude])

    assert_equal "openai_realtime", LiveSetting.default_for(:voice_engine)
    assert_equal "openai_realtime", resolution.engine
    assert_not resolution.fallback?
  end

  test "GPT-Live with Claude runs when it is chosen, both keys are set and the client can speak it" do
    stub_live_key
    stub_claude_key
    use_voice_engine("gpt_live_claude")

    resolution = LiveConversations::VoiceEngine.resolve(@conversation, client_engines: %w[gpt_live_claude])

    assert_equal "gpt_live_claude", resolution.engine
    assert_nil resolution.fallback_reason
  end

  test "a missing key falls back to Realtime and names the key" do
    stub_live_key
    LiveConversations::ClaudeClient.stubs(:api_key).returns(nil)
    use_voice_engine("gpt_live_claude")

    resolution = LiveConversations::VoiceEngine.resolve(@conversation, client_engines: %w[gpt_live_claude])

    assert_equal "openai_realtime", resolution.engine
    assert_equal "gpt_live_claude", resolution.requested
    assert_equal "LIVE_ANTHROPIC_API_KEY is not set", resolution.fallback_reason
  end

  test "a client that cannot run the engine (the iOS app today) falls back" do
    stub_live_key
    stub_claude_key
    use_voice_engine("gpt_live_claude")

    resolution = LiveConversations::VoiceEngine.resolve(@conversation, client_engines: [])

    assert_equal "openai_realtime", resolution.engine
    assert_match(/only the web call dock/, resolution.fallback_reason)
  end

  test "the LiveKit engine is not built, so it always falls back" do
    use_voice_engine("livekit_claude")

    resolution = LiveConversations::VoiceEngine.resolve(@conversation, client_engines: %w[livekit_claude gpt_live_claude])

    assert_equal "openai_realtime", resolution.engine
    assert_match(/not built yet/, resolution.fallback_reason)
  end

  test "an engine at its spend cap falls back; near it, the call runs with a warning" do
    stub_live_key
    stub_claude_key
    use_voice_engine("gpt_live_claude", voice_engine_conversation_cap_usd: 1.0)

    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1",
                           seconds: 60 * 17, live_conversation: @conversation) # $0.85
    near = LiveConversations::VoiceEngine.resolve(@conversation, client_engines: %w[gpt_live_claude])
    assert_equal "gpt_live_claude", near.engine
    assert_match(/\$0\.85 of its \$1\.00 per-conversation cap/, near.warning)

    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1",
                           seconds: 60 * 3, live_conversation: @conversation) # $1.00
    capped = LiveConversations::VoiceEngine.resolve(@conversation, client_engines: %w[gpt_live_claude])
    assert_equal "openai_realtime", capped.engine
    assert_match(/per-conversation cap/, capped.fallback_reason)
  end
end

class LiveConversations::VoiceEngineSettingsTest < ActiveSupport::TestCase
  test "the live model can switch its engine by voice, but cannot raise its own spend caps" do
    conversation = create_live_conversation(mode: "voice")
    bridge = LiveConversations::ToolBridge.new(conversation)

    switched = bridge.execute("update_live_settings", { "voice_engine" => "gpt_live_claude" }, call_id: "c1")
    assert_not switched.error
    assert_includes switched.output, "Voice engine"
    assert_includes switched.output, "from the next call"
    assert_equal "gpt_live_claude", LiveSetting.current.effective(:voice_engine)

    raised = bridge.execute("update_live_settings", { "voice_engine_daily_cap_usd" => 500 }, call_id: "c2")
    assert raised.error
    assert_equal 10.0, LiveSetting.current.effective(:voice_engine_daily_cap_usd)
  end
end
