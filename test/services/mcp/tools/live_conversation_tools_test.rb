# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::LiveConversationToolsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    context = Mcp::Context.new(tool_groups: "live_conversations", base_url: "https://zimmer.example.com")
    @get = Mcp::Tools::GetLiveConversations.new(context: context)
    @action = Mcp::Tools::ActionLiveConversation.new(context: context)
    stub_live_root
    stub_live_key
  end

  test "both tools are on the live_conversations surface, not sessions, and the read survives _readonly" do
    names = Mcp::Context.new(tool_groups: "live_conversations").tools.map(&:tool_name)
    assert_includes names, "get_live_conversations"
    assert_includes names, "action_live_conversation"

    readonly = Mcp::Context.new(tool_groups: "live_conversations_readonly").tools.map(&:tool_name)
    assert_includes readonly, "get_live_conversations"
    assert_not_includes readonly, "action_live_conversation"

    assert_not_includes Mcp::Context.new(tool_groups: "sessions").tools.map(&:tool_name), "action_live_conversation"
  end

  test "listing says whether Live Mode can start, and the current conversation and its mode" do
    conversation = create_live_conversation(mode: "voice")

    result = @get.call({})

    assert_includes result, "**State:** available"
    assert_includes result, "**Current conversation:** ##{conversation.id} (active, voice)"
    assert_includes result, "voice `gpt-realtime-2.1-mini`"
    assert_includes result, "https://zimmer.example.com/live_conversations/#{conversation.id}"

    stub_live_root(root: nil)
    assert_match(/\*\*State:\*\* off — The catalog has no `live-mode` agent root yet/, @get.call({}))
  end

  test "one conversation's thread, tool calls included, and only the new turns on request" do
    conversation = create_live_conversation(mode: "voice", mode_instructions: { "voice" => "Short." })
    first = conversation.turns.create!(role: "user", source: "spoken", content: "Spin up a docs fix.")
    conversation.turns.create!(role: "tool", tool_name: "zimmer", call_id: "c1", tool_arguments: { "tool" => "quick_router" }, tool_output: "Started session #77")

    result = @get.call("id" => conversation.id)
    assert_includes result, "**user** (spoken): Spin up a docs fix."
    assert_includes result, "**tool** `zimmer` {\"tool\":\"quick_router\"}"
    assert_includes result, "Started session #77"
    assert_includes result, "**Mode:** voice (voice on)"
    assert_includes result, "**Mode styles:** text from Zimmer's default, voice from the agent root"

    newer = @get.call("id" => conversation.id, "after_turn_id" => first.id)
    assert_not_includes newer, "Spin up a docs fix."
  end

  test "start, send_message and finish go through the same rules as the page" do
    started = @action.call("action" => "start", "mode" => "text")
    conversation = LiveConversation.last
    assert_includes started, "**ID:** #{conversation.id}"

    assert_enqueued_with(job: LiveConversationReplyJob) do
      @action.call("action" => "send_message", "id" => conversation.id, "content" => "hello")
    end
    assert_equal "hello", conversation.turns.sole.content

    @action.call("action" => "finish", "id" => conversation.id)
    assert conversation.reload.ended?

    error = assert_raises(Mcp::ToolError) { @action.call("action" => "send_message", "id" => conversation.id, "content" => "again") }
    assert_match(/has ended/, error.message)
  end

  test "start is typed by default, and refuses with the reason when Live Mode is off" do
    @action.call("action" => "start")
    assert LiveConversation.last.text?

    stub_live_root(root: nil)
    error = assert_raises(Mcp::ToolError) { @action.call("action" => "start", "mode" => "voice") }
    assert_match(/live-mode/, error.message)
  end

  test "set_mode turns voice on and off; typing waits for voice to be off" do
    conversation = create_live_conversation(mode: "text")

    result = @action.call("action" => "set_mode", "id" => conversation.id, "mode" => "voice")
    assert_includes result, "spoken (voice on)"
    assert conversation.reload.voice?

    error = assert_raises(Mcp::ToolError) { @action.call("action" => "send_message", "id" => conversation.id, "content" => "hi") }
    assert_match(/Voice is on/, error.message)

    @action.call("action" => "set_mode", "id" => conversation.id, "mode" => "text")
    assert conversation.reload.text?

    error = assert_raises(Mcp::ToolError) { @action.call("action" => "set_mode", "id" => conversation.id, "mode" => "video") }
    assert_match(/mode must be one of/, error.message)
  end
end
