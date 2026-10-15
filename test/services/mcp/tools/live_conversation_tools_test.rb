# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::LiveConversationToolsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    context = Mcp::Context.new(tool_groups: "sessions", base_url: "https://zimmer.example.com")
    @get = Mcp::Tools::GetLiveConversations.new(context: context)
    @action = Mcp::Tools::ActionLiveConversation.new(context: context)
    stub_live_roots
    stub_live_key
  end

  test "both tools are on the sessions surface, and the read survives sessions_readonly" do
    names = Mcp::Context.new(tool_groups: "sessions").tools.map(&:tool_name)
    assert_includes names, "get_live_conversations"
    assert_includes names, "action_live_conversation"

    readonly = Mcp::Context.new(tool_groups: "sessions_readonly").tools.map(&:tool_name)
    assert_includes readonly, "get_live_conversations"
    assert_not_includes readonly, "action_live_conversation"
  end

  test "listing says which modes can start and why not" do
    stub_live_roots(voice: nil)
    conversation = create_live_conversation(mode: "text")

    result = @get.call({})

    assert_match(/\*\*Live Mode\*\* \(`text`.*available; current conversation ##{conversation.id}/, result)
    assert_match(/\*\*Live Voice\*\* .*off — The catalog has no `live-voice` agent root yet/, result)
    assert_includes result, "https://zimmer.example.com/live_conversations/#{conversation.id}"
  end

  test "one conversation's thread, tool calls included, and only the new turns on request" do
    conversation = create_live_conversation(mode: "voice")
    first = conversation.turns.create!(role: "user", source: "spoken", content: "Spin up a docs fix.")
    conversation.turns.create!(role: "tool", tool_name: "zimmer", call_id: "c1", tool_arguments: { "tool" => "quick_router" }, tool_output: "Started session #77")

    result = @get.call("id" => conversation.id)
    assert_includes result, "**user** (spoken): Spin up a docs fix."
    assert_includes result, "**tool** `zimmer` {\"tool\":\"quick_router\"}"
    assert_includes result, "Started session #77"

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

  test "start refuses with the reason when the mode is off" do
    stub_live_roots(voice: nil)

    error = assert_raises(Mcp::ToolError) { @action.call("action" => "start", "mode" => "voice") }
    assert_match(/live-voice/, error.message)
  end

  test "a voice conversation does not take typed messages" do
    conversation = create_live_conversation(mode: "voice")

    error = assert_raises(Mcp::ToolError) { @action.call("action" => "send_message", "id" => conversation.id, "content" => "hi") }
    assert_match(/spoken turns/, error.message)
  end
end
