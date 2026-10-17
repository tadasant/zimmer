# frozen_string_literal: true

require "test_helper"

class LiveConversations::ListeningTest < ActiveSupport::TestCase
  Fake = LiveConversationHelpers::FakeOpenai

  setup do
    @conversation = create_live_conversation(mode: "voice")
  end

  def listen(value)
    LiveConversations::SettingsUpdate.call({ "voice_listening" => value }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
  end

  test "always answers every line and asks no model" do
    client = Fake.new
    listening = LiveConversations::Listening.new(@conversation, mode: "always", client: client)

    assert listening.respond?("so anyway, the banana republic thing")
    assert_empty client.chat_requests
  end

  test "the wake word answers only a line that says Zimmer" do
    listening = LiveConversations::Listening.new(@conversation, mode: "wake_word", client: Fake.new)

    assert listening.respond?("Hey Zimmer, is main green?")
    assert listening.respond?("what's on zimmer's board")
    assert listening.respond?("Is main green, Zimmer?")
    refute listening.respond?("I don't know. Hello, can you hear me?")
    refute listening.respond?("사주")
  end

  test "dynamic asks a model about a line without the wake word, with the thread for context" do
    @conversation.turns.create!(role: "assistant", source: "spoken", content: "Want me to start the docs fix?", created_at: 1.minute.ago)
    client = Fake.new(chat_responses: [ Fake.text("yes"), Fake.text("No.") ])
    listening = LiveConversations::Listening.new(@conversation, mode: "dynamic", client: client)

    assert listening.respond?("Yes please, go ahead.")
    refute listening.respond?("Did you grab the groceries?")

    request = client.chat_requests.first
    assert_equal "none", request["reasoning_effort"]
    assert_includes request["messages"].last["content"], "Zimmer: Want me to start the docs fix?"
    assert request["messages"].last["content"].end_with?("Heard: Yes please, go ahead.")
  end

  test "dynamic answers the wake word without asking, and answers when the judge cannot be reached" do
    client = Fake.new(chat_responses: [ OpenaiClient::Error.new("OpenAI did not answer in time (ReadTimeout)") ])
    listening = LiveConversations::Listening.new(@conversation, mode: "dynamic", client: client)

    assert listening.respond?("Zimmer, what time is it?")
    assert_empty client.chat_requests
    assert listening.respond?("what time is it")
  end

  test "a follow-up soon after the last line needs no wake word, and a later one does" do
    @conversation.turns.create!(role: "assistant", source: "spoken", content: "Want me to start the docs fix?")
    listening = LiveConversations::Listening.new(@conversation, mode: "wake_word", client: Fake.new)

    assert listening.respond?("Yes please.")
    travel 11.seconds do
      refute listening.respond?("Did you grab the groceries?")
    end
  end

  test "the assistant's own voice through the speaker is dropped, even when it says Zimmer" do
    @conversation.turns.create!(role: "assistant", source: "spoken", content: "Zimmer here. Main is green, and the docs fix is merged.")
    client = Fake.new
    listening = LiveConversations::Listening.new(@conversation, mode: "dynamic", client: client)

    refute listening.respond?("Zimmer here. Main is green")
    refute listening.respond?("main is green, and the docs fix")
    assert listening.respond?("okay"), "a short line inside it is a coincidence, and a follow-up"
    assert_empty client.chat_requests
  end

  test "silence turn detection is gated the same way" do
    LiveConversations::SettingsUpdate.call({ "voice_listening" => "wake_word", "voice_turn_detection" => "server_vad" },
      actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    client = Fake.new

    LiveConversations::RealtimeSession.mint(@conversation, client: client, listening_modes: true)

    detection = client.secret_requests.sole.dig("session", "audio", "input", "turn_detection")
    assert_equal [ "server_vad", false, false ], detection.values_at("type", "create_response", "interrupt_response")
  end

  test "settings OpenAI refuses fall back to the defaults but keep Listening" do
    listen("wake_word")
    LiveConversations::SettingsUpdate.call({ "voice_reasoning_effort" => "xhigh" }, actor: LiveConversations::SettingsUpdate::Actor.human("test"))
    client = Fake.new(secret_failures: [ OpenaiClient::Error.new("OpenAI answered 400: unsupported effort", status: 400) ])

    minted = LiveConversations::RealtimeSession.mint(@conversation, client: client, listening_modes: true)

    assert_equal "wake_word", minted[:listening]
    assert_nil client.secret_requests.last.dig("session", "reasoning")
  end

  test "the mode is the setting for a client that can gate, and always for one that cannot" do
    assert_equal "always", LiveConversations::Listening.mode
    listen("wake_word")

    assert_equal "wake_word", LiveConversations::Listening.mode
    assert_equal "always", LiveConversations::Listening.mode(capable: false)
  end

  test "a gated call's turn detection neither starts nor cuts off a reply, and the client is told the mode" do
    listen("dynamic")
    client = Fake.new

    minted = LiveConversations::RealtimeSession.mint(@conversation, client: client, listening_modes: true)

    assert_equal "dynamic", minted[:listening]
    detection = client.secret_requests.sole.dig("session", "audio", "input", "turn_detection")
    assert_equal [ false, false ], detection.values_at("create_response", "interrupt_response")
    update = LiveConversations::RealtimeSession.new(@conversation, listening_modes: true).session_update
    assert_equal false, update.dig(:audio, :input, :turn_detection, :create_response)
  end

  test "a client that cannot gate gets a call that answers everything, whatever the setting" do
    listen("wake_word")
    client = Fake.new

    minted = LiveConversations::RealtimeSession.mint(@conversation, client: client)

    assert_equal "always", minted[:listening]
    detection = client.secret_requests.sole.dig("session", "audio", "input", "turn_detection")
    assert_equal [ true, true ], detection.values_at("create_response", "interrupt_response")
  end

  test "recording a heard line keeps and answers it, or drops it unwritten" do
    listen("wake_word")
    actions = LiveConversations::Actions.new(@conversation, listening_modes: true)

    dropped = actions.record_turn(role: "user", content: "One Banana Republic has cell charts.")
    kept = actions.record_turn(role: "user", content: "Zimmer, can you hear me?")
    reply = actions.record_turn(role: "assistant", content: "Loud and clear.")

    assert_equal({ respond: false, dropped: true }, dropped.as_api_json)
    assert kept.respond
    assert_equal true, kept.as_api_json[:respond]
    assert reply.respond
    assert_equal [ "Zimmer, can you hear me?", "Loud and clear." ], @conversation.turns.map(&:content)
    # An app that cannot gate keeps every line, as before.
    assert LiveConversations::Actions.new(@conversation).record_turn(role: "user", content: "anything at all").turn
  end
end
