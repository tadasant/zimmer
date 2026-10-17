# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class LiveConversations::StartTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "starts a typed conversation on the live-mode root, seeded from its default servers, and prepares it" do
    stub_live_root
    stub_live_key

    conversation = nil
    assert_enqueued_with(job: LiveConversationPrepareJob) { conversation = LiveConversations::Start.call }

    assert conversation.preparing?
    assert conversation.text?
    assert_equal "live-mode", conversation.agent_root
    assert_equal "gpt-6-luna", conversation.model
    assert_equal [ "zimmer" ], conversation.mcp_servers
  end

  test "starting with voice is the same conversation on the same root, spoken from the start" do
    stub_live_root
    stub_live_key

    conversation = LiveConversations::Start.call("voice")

    assert conversation.voice?
    assert_equal "live-mode", conversation.agent_root
    assert_equal "gpt-realtime-2.1-mini", conversation.model
  end

  test "there is one current conversation: starting a new one ends the old one, whatever its mode" do
    stub_live_root
    stub_live_key
    old = create_live_conversation(mode: "voice")

    fresh = LiveConversations::Start.call("text")

    assert old.reload.ended?
    assert_equal fresh, LiveConversation.current
  end

  test "the database refuses a second open conversation, typed or spoken" do
    create_live_conversation(mode: "text")

    assert_raises(ActiveRecord::RecordNotUnique) { create_live_conversation(mode: "voice") }
  end

  test "an unknown mode is refused" do
    stub_live_root
    stub_live_key

    assert_raises(KeyError) { LiveConversations::Start.call("video") }
  end

  test "a missing root or key refuses with words a human can act on" do
    stub_live_root(root: nil)
    OpenaiClient.stubs(:api_key).returns(nil)

    error = assert_raises(LiveConversations::Start::Unavailable) { LiveConversations::Start.call }

    assert_match(/LIVE_OPENAI_API_KEY is not set/, error.message)
    assert_match(/The catalog has no `live-mode` agent root yet/, error.message)
    assert_equal 0, LiveConversation.count
  end

  test "availability reports each prerequisite, and each mode's model, for the API" do
    stub_live_root(root: nil)
    stub_live_key

    json = LiveConversations::Availability.current.as_api_json

    assert_equal "Live Mode", json[:label]
    assert_equal "live-mode", json[:agent_root]
    assert_equal false, json[:available]
    assert_equal true, json[:key_configured]
    assert_equal false, json[:root_present]
    assert_equal 1, json[:reasons].size
    assert_equal %w[text voice], json[:modes].pluck(:mode)
    assert_equal [ "gpt-6-luna", "gpt-realtime-2.1-mini" ], json[:modes].pluck(:model)
    assert(json[:modes].all? { |mode| mode[:available] == false && mode[:agent_root] == "live-mode" })
  end

  test "switching mode keeps the conversation and its thread, and the model follows the mode" do
    conversation = create_live_conversation(mode: "text")
    conversation.turns.create!(role: "user", source: "typed", content: "hi")

    LiveConversations::Actions.new(conversation).switch_mode("voice")

    conversation.reload
    assert conversation.voice?
    assert conversation.active?
    assert_equal "gpt-realtime-2.1-mini", conversation.model
    assert_equal 1, conversation.turns.count

    LiveConversations::Actions.new(conversation).switch_mode("text")
    assert_equal "gpt-6-luna", conversation.reload.model
  end

  test "turning voice off answers a typed message voice never heard" do
    conversation = create_live_conversation(mode: "voice")
    conversation.turns.create!(role: "user", source: "typed", content: "typed while preparing")

    assert_enqueued_with(job: LiveConversationReplyJob, args: [ conversation.id ]) do
      LiveConversations::Actions.new(conversation).switch_mode("text")
    end
    assert_no_enqueued_jobs(only: LiveConversationReplyJob) { LiveConversations::Actions.new(conversation).switch_mode("text") }
  end

    test "switching refuses an unknown mode and a closed conversation" do
    conversation = create_live_conversation(mode: "text")
    error = assert_raises(LiveConversations::Actions::Refused) { LiveConversations::Actions.new(conversation).switch_mode("video") }
    assert_match(/mode must be one of: text, voice/, error.message)

    conversation.end!
    error = assert_raises(LiveConversations::Actions::Refused) { LiveConversations::Actions.new(conversation).switch_mode("voice") }
    assert_equal :conflict, error.status
  end

  test "typing is refused while voice is on, and the voice relay is refused while it is off" do
    conversation = create_live_conversation(mode: "voice")
    error = assert_raises(LiveConversations::Actions::Refused) { LiveConversations::Actions.new(conversation).post_message("hi") }
    assert_match(/Voice is on/, error.message)

    conversation.switch_mode!("text")
    error = assert_raises(LiveConversations::Actions::Refused) { LiveConversations::Actions.new(conversation).client_secret }
    assert_match(/Voice is off/, error.message)
  end

  test "a call still connected when voice goes off keeps its transcript and tool calls" do
    conversation = create_live_conversation(mode: "voice")
    conversation.switch_mode!("text")

    turn = LiveConversations::Actions.new(conversation).record_turn(role: "assistant", content: "Okay, done.").turn

    assert_equal "spoken", turn.source
  end
end
