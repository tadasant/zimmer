# frozen_string_literal: true

require "test_helper"

# What the live model is told depends on the mode the conversation is in right
# now: the root's style file for that mode when it ships one, Zimmer's default
# when it does not.
class LiveConversations::SystemPromptTest < ActiveSupport::TestCase
  test "typed: the typed style, after AGENTS.md and Zimmer's mechanics" do
    prompt = LiveConversations::SystemPrompt.build(create_live_conversation(mode: "text"))

    assert prompt.start_with?("# Live\nBe brief.")
    assert_operator prompt.index("## This conversation (written by Zimmer)"), :<, prompt.index("## Right now: typed")
    assert_includes prompt, "Right now it is typed."
    assert_includes prompt, "Longer answers are fine when they help"
    assert_not_includes prompt, "you are heard, not read"
  end

  test "spoken: the spoken style, and nothing of the typed one" do
    prompt = LiveConversations::SystemPrompt.build(create_live_conversation(mode: "voice"))

    assert_includes prompt, "Right now it is spoken."
    assert_includes prompt, "## Right now: spoken"
    assert_includes prompt, "Never read out markdown"
    assert_not_includes prompt, "Longer answers are fine"
  end

  test "the root's style file for the mode replaces Zimmer's default, for that mode only" do
    conversation = create_live_conversation(mode: "voice", mode_instructions: { "voice" => "Speak like a radio host." })

    spoken = LiveConversations::SystemPrompt.build(conversation)
    assert_includes spoken, "Speak like a radio host."
    assert_not_includes spoken, "Never read out markdown"

    conversation.switch_mode!("text")
    typed = LiveConversations::SystemPrompt.build(conversation)
    assert_includes typed, "Longer answers are fine when they help"
    assert_not_includes typed, "radio host"
  end

  test "a switch is in the very next typed request" do
    conversation = create_live_conversation(mode: "voice")
    conversation.turns.create!(role: "user", source: "spoken", content: "Start the docs fix.")
    conversation.switch_mode!("text")
    conversation.turns.create!(role: "user", source: "typed", content: "Show me the PR list.")
    client = LiveConversationHelpers::FakeOpenai.new(chat_responses: [ LiveConversationHelpers::FakeOpenai.text("Here.") ])

    LiveConversations::TextReply.call(conversation, client: client)

    request = client.chat_requests.sole
    assert_equal "gpt-6-luna", request["model"]
    assert_includes request["messages"].first["content"], "## Right now: typed"
    assert_equal [ "Start the docs fix.", "Show me the PR list." ], request["messages"].select { |m| m["role"] == "user" }.pluck("content")
  end
end
