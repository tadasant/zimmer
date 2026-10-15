# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversationJobsTest < ActiveJob::TestCase
  Fake = LiveConversationHelpers::FakeOpenai

  test "prepare: reads the root's AGENTS.md, lists default servers' tools, and goes active" do
    stub_live_roots
    stub_clock_server
    conversation = create_live_conversation(mode: "voice", status: LiveConversation::PREPARING, mcp_servers: [ "zimmer", "test-clock" ], instructions: nil)
    LiveConversations::RootInstructions.expects(:fetch).returns(
      LiveConversations::RootInstructions::Result.new(text: "# Live Voice\nBe quick.", source: "example/live@abc:agent-roots/live-voice/AGENTS.md")
    )

    LiveConversationPrepareJob.perform_now(conversation.id)

    conversation.reload
    assert conversation.active?
    assert_equal "# Live Voice\nBe quick.", conversation.instructions
    assert_equal "example/live@abc:agent-roots/live-voice/AGENTS.md", conversation.instructions_source
    assert_equal %w[zimmer test-clock], conversation.mcp_servers
    assert_equal %w[current_time env_names], conversation.mcp_tool_cache["test-clock"].map { |t| t["name"] }
  end

  test "prepare: a default server that cannot start is dropped with a note, not fatal" do
    stub_live_roots
    ServersConfig.stubs(:find).with("broken").returns(ServersConfig::Server.new("broken", { "type" => "stdio", "command" => "/nonexistent" }))
    conversation = create_live_conversation(mode: "text", status: LiveConversation::PREPARING, mcp_servers: [ "zimmer", "broken" ])
    LiveConversations::RootInstructions.stubs(:fetch).returns(LiveConversations::RootInstructions::Result.new(text: "x", source: "s"))

    LiveConversationPrepareJob.perform_now(conversation.id)

    assert conversation.reload.active?
    assert_equal %w[zimmer], conversation.mcp_servers
    assert_match(/Could not enable broken:/, conversation.error_message)
  end

  test "prepare: unreadable instructions fail the conversation with the reason" do
    stub_live_roots
    conversation = create_live_conversation(mode: "text", status: LiveConversation::PREPARING)
    LiveConversations::RootInstructions.stubs(:fetch).raises(LiveConversations::RootInstructions::Error, "Agent root live-mode has no AGENTS.md")

    LiveConversationPrepareJob.perform_now(conversation.id)

    assert conversation.reload.failed?
    assert_equal "Agent root live-mode has no AGENTS.md", conversation.error_message
  end

  test "prepare: a message typed while preparing is answered once active" do
    stub_live_roots
    conversation = create_live_conversation(mode: "text", status: LiveConversation::PREPARING)
    conversation.turns.create!(role: "user", source: "typed", content: "early")
    LiveConversations::RootInstructions.stubs(:fetch).returns(LiveConversations::RootInstructions::Result.new(text: "x", source: "s"))

    assert_enqueued_with(job: LiveConversationReplyJob, args: [ conversation.id ]) do
      LiveConversationPrepareJob.perform_now(conversation.id)
    end
  end

  test "reply: answers, and releases the claim" do
    conversation = create_live_conversation(mode: "text")
    conversation.turns.create!(role: "user", source: "typed", content: "hi")
    OpenaiClient.stubs(:new).returns(Fake.new(chat_responses: [ Fake.text("Hello.") ]))

    LiveConversationReplyJob.perform_now(conversation.id)

    assert_equal "Hello.", conversation.turns.last.content
    assert_nil conversation.reload.responding_since
  end

  test "reply: an OpenAI failure lands on the page, not in a crash loop" do
    conversation = create_live_conversation(mode: "text")
    conversation.turns.create!(role: "user", source: "typed", content: "hi")
    OpenaiClient.stubs(:new).returns(Fake.new(chat_responses: [ OpenaiClient::Error.new("OpenAI answered 429: Rate limit") ]))

    assert_no_enqueued_jobs(only: LiveConversationReplyJob) { LiveConversationReplyJob.perform_now(conversation.id) }

    assert_equal "OpenAI: OpenAI answered 429: Rate limit", conversation.reload.error_message
    assert_nil conversation.responding_since
  end

  test "reply: a fresh claim held by another job is respected" do
    conversation = create_live_conversation(mode: "text", responding_since: 10.seconds.ago)
    conversation.turns.create!(role: "user", source: "typed", content: "hi")
    OpenaiClient.expects(:new).never

    LiveConversationReplyJob.perform_now(conversation.id)
  end

  test "reply: a stale claim is taken over" do
    conversation = create_live_conversation(mode: "text", responding_since: 10.minutes.ago)
    conversation.turns.create!(role: "user", source: "typed", content: "hi")
    OpenaiClient.stubs(:new).returns(Fake.new(chat_responses: [ Fake.text("Back.") ]))

    LiveConversationReplyJob.perform_now(conversation.id)

    assert_equal "Back.", conversation.turns.last.content
  end
end
