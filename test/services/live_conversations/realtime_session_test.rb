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
    assert_equal minted[:tools].map { |t| t[:name] }, %w[zimmer describe_zimmer_tool list_mcp_servers enable_mcp_server disable_mcp_server]

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
end
