# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversations::TextReplyTest < ActiveSupport::TestCase
  Fake = LiveConversationHelpers::FakeOpenai

  setup do
    @conversation = create_live_conversation(mode: "text")
  end

  test "a plain question gets a plain answer, with the root's AGENTS.md as the system prompt" do
    @conversation.turns.create!(role: "user", source: "typed", content: "hi")
    client = Fake.new(chat_responses: [ Fake.text("Hello.") ])

    LiveConversations::TextReply.call(@conversation, client: client)

    assert_equal [ "user", "assistant" ], @conversation.turns.map(&:role)
    assert_equal "Hello.", @conversation.turns.last.content
    request = client.chat_requests.first
    assert_equal "gpt-6-luna", request["model"]
    assert_equal "none", request["reasoning_effort"]
    system = request["messages"].first
    assert_equal "system", system["role"]
    assert system["content"].start_with?("# Live\nBe brief.")
    assert_includes system["content"], "## This conversation (written by Zimmer)"
    assert_includes request["tools"].map { |t| t.dig("function", "name") }, "zimmer"
  end

  test "a tool call runs through the bridge and its result is fed back as a tool message" do
    @conversation.turns.create!(role: "user", source: "typed", content: "how is zimmer?")
    client = Fake.new(chat_responses: [
      Fake.calls([ "zimmer", { tool: "get_system_health", arguments: {} } ]),
      Fake.text("All healthy.")
    ])

    LiveConversations::TextReply.call(@conversation, client: client)

    assert_equal %w[user tool assistant], @conversation.turns.map(&:role)
    second = client.chat_requests.second["messages"]
    assert_equal %w[system user assistant tool], second.map { |m| m["role"] }
    assert_equal "call_0_zimmer", second[2]["tool_calls"].first["id"]
    assert_equal "get_system_health", JSON.parse(second[2]["tool_calls"].first.dig("function", "arguments"))["tool"]
    assert_equal "call_0_zimmer", second[3]["tool_call_id"]
    assert_match(/System Health/, second[3]["content"])
  end

  test "enabling a server mid-reply makes its tools available on the next round" do
    stub_clock_server
    @conversation.turns.create!(role: "user", source: "typed", content: "what time is it?")
    client = Fake.new(chat_responses: [
      Fake.calls([ "enable_mcp_server", { name: "test-clock" } ]),
      Fake.calls([ "test-clock__current_time", {} ]),
      Fake.text("Noon.")
    ])

    LiveConversations::TextReply.call(@conversation, client: client)

    assert_includes client.chat_requests.second["tools"].map { |t| t.dig("function", "name") }, "test-clock__current_time"
    assert_equal "It is noon. hello", @conversation.turns.where(tool_name: "test-clock__current_time").sole.tool_output
    assert_equal "Noon.", @conversation.turns.last.content
  end

  test "a model that never stops calling tools is cut off with an explanation" do
    @conversation.turns.create!(role: "user", source: "typed", content: "loop")
    responses = Array.new(LiveConversations::TextReply::MAX_ROUNDS) { Fake.calls([ "list_mcp_servers", {} ]) }

    LiveConversations::TextReply.call(@conversation, client: Fake.new(chat_responses: responses))

    assert_match(/stopped after #{LiveConversations::TextReply::MAX_ROUNDS} rounds/, @conversation.turns.last.content)
    assert_not LiveConversations::TextReply.awaiting_reply?(@conversation)
  end

  test "a message typed while the reply was running is answered in the same loop" do
    @conversation.turns.create!(role: "user", source: "typed", content: "first")
    client = Fake.new(chat_responses: [ Fake.text("One."), Fake.text("Two.") ])
    client.define_singleton_method(:chat_completion) do |body|
      result = super(body)
      LiveConversation.last.turns.create!(role: "user", source: "typed", content: "second") if chat_requests.size == 1
      result
    end

    LiveConversations::TextReply.call(@conversation, client: client)

    # "second" landed while the first request was in flight, so it sits before
    # that request's answer — and is still answered.
    assert_equal [ "first", "second", "One.", "Two." ], @conversation.turns.map(&:content)
    assert_equal %w[system user user assistant], client.chat_requests.second["messages"].map { |m| m["role"] }
  end
end
