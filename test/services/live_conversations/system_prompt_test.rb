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

  # The one fact only Zimmer knows about the person's situation: which client is
  # driving the conversation. Stated when it is CarPlay, silent otherwise, and
  # rebuilt with the rest of the prompt so a move from the car to the phone
  # changes the next answer.
  test "a conversation driven from CarPlay is told so, in the mechanics section, naming the carplay_fit tools" do
    conversation = create_live_conversation(mode: "voice", client_surface: "carplay")

    prompt = LiveConversations::SystemPrompt.build(conversation)

    assert_includes prompt, "The client driving this conversation right now is CarPlay"
    assert_includes prompt, "set_carplay_fit"
    assert_operator prompt.index("## This conversation (written by Zimmer)"), :<, prompt.index("is CarPlay")
    assert_operator prompt.index("is CarPlay"), :<, prompt.index("## Right now: spoken")

    conversation.update_column(:client_surface, "ios")
    assert_not_includes LiveConversations::SystemPrompt.build(conversation.reload), "is CarPlay"
  end

  # A lookup is not triage: the CarPlay-fit filter that drops laptop-only rows from
  # "what needs me" must not drop the session the driver is asking about.
  test "a CarPlay conversation is told to keep carplay_fit off a search for a particular session" do
    prompt = LiveConversations::SystemPrompt.build(create_live_conversation(mode: "voice", client_surface: "carplay"))

    assert_includes prompt, "Leave `carplay_fit` off a search for a particular session"
    assert_not_includes prompt, "`get_user_view` and `quick_search_sessions` take a"
  end

  test "every conversation is told how to find an earlier session, archived ones included" do
    prompt = LiveConversations::SystemPrompt.build(create_live_conversation(mode: "text"))

    assert_includes prompt, "To find an earlier session the person remembers"
    assert_includes prompt, "includes archived sessions"
    assert_includes prompt, "search_contents: true"
  end

  test "says how to go back, and a call's recap names the sessions the thread touched" do
    conversation = create_live_conversation(mode: "voice")
    conversation.turns.create!(role: "tool", tool_name: "zimmer", call_id: "c1", tool_arguments: { "tool" => "quick_router" }, tool_output: "Started session #1101")

    prompt = LiveConversations::SystemPrompt.build(conversation, recap: true)

    assert_includes prompt, "`switch_live_conversation`"
    assert_includes prompt, "#1101"
    assert_not_includes LiveConversations::SystemPrompt.build(conversation), "## Sessions this conversation has touched"
  end
end
