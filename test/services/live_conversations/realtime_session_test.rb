# frozen_string_literal: true

require "test_helper"

class LiveConversations::RealtimeSessionTest < ActiveSupport::TestCase
  test "mints a client secret whose session config Zimmer decides, and hands the client what it needs" do
    conversation = create_live_conversation(mode: "voice")
    conversation.turns.create!(role: "user", source: "spoken", content: "Start the docs fix.")
    conversation.turns.create!(role: "assistant", source: "spoken", content: "Started it.")
    client = LiveConversationHelpers::FakeOpenai.new

    minted = LiveConversations::RealtimeSession.mint(conversation, client: client)

    assert_equal "ek_test_123", minted[:client_secret]
    assert_equal "gpt-realtime-2.1-mini", minted[:model]
    assert_equal "https://api.openai.com/v1/realtime/calls", minted[:calls_url]
    assert_equal "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini", minted[:websocket_url]
    assert_equal minted[:tools].map { |t| t[:name] }, %w[zimmer describe_zimmer_tool list_mcp_servers enable_mcp_server disable_mcp_server get_live_settings update_live_settings]

    body = client.secret_requests.sole
    assert_equal({ "anchor" => "created_at", "seconds" => 600 }, body["expires_after"])
    session = body["session"]
    assert_equal "realtime", session["type"]
    assert_equal "gpt-realtime-2.1-mini", session["model"]
    assert_equal "marin", session.dig("audio", "output", "voice")
    assert_equal "gpt-4o-mini-transcribe", session.dig("audio", "input", "transcription", "model")
    assert_equal "semantic_vad", session.dig("audio", "input", "turn_detection", "type")
    assert session["instructions"].start_with?("# Live\nBe brief.")
    assert_includes session["instructions"], "Answer out loud"
    # A reconnecting call is reminded of what was already said.
    assert_includes session["instructions"], "Them: Start the docs fix.\nYou: Started it."
  end

  test "a response with no secret is an error, not a blank token" do
    client = LiveConversationHelpers::FakeOpenai.new(secret: {})

    assert_raises(OpenaiClient::Error) do
      LiveConversations::RealtimeSession.mint(create_live_conversation(mode: "voice"), client: client)
    end
  end

  test "the session config is the Live settings, with the guidance last in the instructions" do
    LiveConversations::SettingsUpdate.call(
      { "voice_model" => "gpt-realtime-2.1", "voice_name" => "cedar", "voice_speed" => 1.25, "voice_reasoning_effort" => "low",
        "voice_turn_detection" => "server_vad", "voice_vad_silence_duration_ms" => 800, "voice_max_output_tokens" => 1024,
        "voice_noise_reduction" => "far_field", "guidance" => "Talk like a pilot." },
      actor: LiveConversations::SettingsUpdate::Actor.human("test")
    )
    conversation = create_live_conversation(mode: "voice")
    client = LiveConversationHelpers::FakeOpenai.new

    minted = LiveConversations::RealtimeSession.mint(conversation, client: client)

    session = client.secret_requests.sole["session"]
    assert_equal "gpt-realtime-2.1", session["model"]
    assert_equal "gpt-realtime-2.1", minted[:model]
    assert_equal "gpt-realtime-2.1", conversation.reload.model
    assert_equal({ "voice" => "cedar", "speed" => 1.25 }, session.dig("audio", "output"))
    assert_equal({ "effort" => "low" }, session["reasoning"])
    assert_equal 1024, session["max_output_tokens"]
    assert_equal({ "type" => "far_field" }, session.dig("audio", "input", "noise_reduction"))
    detection = session.dig("audio", "input", "turn_detection")
    assert_equal "server_vad", detection["type"]
    assert_equal 800, detection["silence_duration_ms"]
    assert_in_delta 0.5, detection["threshold"]
    assert session["instructions"].end_with?("Talk like a pilot.")
  end

  test "settings OpenAI refuses start the call on the defaults rather than not at all" do
    LiveConversations::SettingsUpdate.call({ "voice_reasoning_effort" => "xhigh", "guidance" => "Stay terse." }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    client = LiveConversationHelpers::FakeOpenai.new(secret_failures: [ OpenaiClient::Error.new("OpenAI answered 400: unsupported effort", status: 400) ])

    minted = LiveConversations::RealtimeSession.mint(create_live_conversation(mode: "voice"), client: client)

    assert_equal "ek_test_123", minted[:client_secret]
    assert_match(/runs on the defaults/, minted[:settings_warning])
    assert_equal({ "effort" => "xhigh" }, client.secret_requests.first.dig("session", "reasoning"))
    assert_nil client.secret_requests.second.dig("session", "reasoning")
    assert client.secret_requests.second.dig("session", "instructions").end_with?("Stay terse."), "the fallback keeps the guidance"
  end

  test "a mid-call update carries what a call can change, and never the model or the voice" do
    LiveConversations::SettingsUpdate.call({ "voice_speed" => 1.4, "voice_name" => "cedar", "guidance" => "Shorter." },
                                           actor: LiveConversations::SettingsUpdate::Actor.human("test"))

    update = LiveConversations::RealtimeSession.new(create_live_conversation(mode: "voice")).session_update

    assert_equal "realtime", update[:type]
    assert_equal({ speed: 1.4 }, update.dig(:audio, :output))
    assert_nil update[:model]
    assert_equal "inf", update[:max_output_tokens]
    assert update[:instructions].end_with?("Shorter.")
    assert update.dig(:audio, :input).key?(:noise_reduction)
    assert_includes update[:tools].map { |t| t[:name] }, "update_live_settings"
  end
end
