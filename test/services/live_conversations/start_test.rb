# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversations::StartTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "starts a preparing conversation seeded from the root's default servers, and prepares it" do
    stub_live_roots
    stub_live_key

    conversation = nil
    assert_enqueued_with(job: LiveConversationPrepareJob) { conversation = LiveConversations::Start.call("voice") }

    assert conversation.preparing?
    assert_equal "live-voice", conversation.agent_root
    assert_equal "gpt-realtime-2.1-mini", conversation.model
    assert_equal [ "zimmer" ], conversation.mcp_servers
  end

  test "a mode has one current conversation: starting a new one ends the old one" do
    stub_live_roots
    stub_live_key
    old = create_live_conversation(mode: "text")
    other_mode = create_live_conversation(mode: "voice")

    fresh = LiveConversations::Start.call("text")

    assert old.reload.ended?
    assert other_mode.reload.active?
    assert_equal fresh, LiveConversation.current("text")
  end

  test "the database refuses a second open conversation in a mode" do
    create_live_conversation(mode: "text")

    assert_raises(ActiveRecord::RecordNotUnique) { create_live_conversation(mode: "text") }
  end

  test "a missing root or key refuses with words a human can act on" do
    stub_live_roots(text: nil)
    OpenaiClient.stubs(:api_key).returns(nil)

    error = assert_raises(LiveConversations::Start::Unavailable) { LiveConversations::Start.call("text") }

    assert_match(/LIVE_OPENAI_API_KEY is not set/, error.message)
    assert_match(/The catalog has no `live-mode` agent root yet/, error.message)
    assert_equal 0, LiveConversation.count
  end

  test "availability reports each prerequisite for the API" do
    stub_live_roots(voice: nil)
    stub_live_key

    json = LiveConversations::Availability.for("voice").as_api_json

    assert_equal false, json[:available]
    assert_equal true, json[:key_configured]
    assert_equal false, json[:root_present]
    assert_equal 1, json[:reasons].size
  end
end
