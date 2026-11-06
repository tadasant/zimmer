# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The whole of "start a new one, then go back", through the routes a client uses,
# with the job adapter running what they enqueue and OpenAI scripted: a voice call
# on one conversation, a new conversation, the model moved back mid-call, and the
# secret the reattached call opens with carrying the old thread and its tools.
class LiveSwitchBackFlowTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    stub_live_root
    stub_live_key
    @openai = LiveConversationHelpers::FakeOpenai.new
    OpenaiClient.stubs(:new).returns(@openai)
    LiveConversations::RootInstructions.stubs(:fetch).returns(
      LiveConversations::RootInstructions::Result.new(text: "# Live\nBe brief.", source: "test", modes: {})
    )
  end

  def post_json(path, body = {})
    post path, params: body, as: :json
    response.parsed_body
  end

  test "start new, go back by voice, and the call lands on the old thread with one conversation open" do
    first = perform_enqueued_jobs(only: LiveConversationPrepareJob) { LiveConversations::Start.call("voice", client_surface: "web") }
    post_json "/live_conversations/#{first.id}/turns", role: "user", content: "Deploy the fix to staging when green"
    post_json "/live_conversations/#{first.id}/turns", role: "assistant", content: "Started a session for that."
    first.reload.turns.create!(role: "tool", tool_name: "zimmer", call_id: "c0", tool_arguments: { "tool" => "quick_router" }, tool_output: "Started session #1101")

    second = perform_enqueued_jobs(only: LiveConversationPrepareJob) { LiveConversations::Start.call("voice", client_surface: "web") }
    post_json "/live_conversations/#{second.id}/turns", role: "user", content: "Actually, take me back"

    moved = perform_enqueued_jobs(only: LiveConversationPrepareJob) do
      post_json "/live_conversations/#{second.id}/tool_calls", name: "switch_live_conversation", arguments: "{}", call_id: "c1", reattaches: 1, listening_modes: 1
    end
    assert_equal first.id, moved.dig("switched_to", "id")
    assert_nil moved["session"]

    get "/live/current.json"
    assert_equal first.id, response.parsed_body["current_id"]
    assert_equal 1, LiveConversation.unfinished.count

    secret = post_json "/live_conversations/#{first.id}/client_secret", listening_modes: 1
    assert_equal "ek_test_123", secret["client_secret"]
    instructions = @openai.secret_requests.last.dig("session", "instructions")
    assert_includes instructions, "Deploy the fix to staging when green"
    assert_includes instructions, "#1101"
    assert_not_includes instructions, "Actually, take me back"
    assert_includes secret["tools"].map { |tool| tool["name"] }, "switch_live_conversation"

    post_json "/live_conversations/#{second.id}/turns", role: "user", content: "a line from a stale screen"
    assert_response :conflict
    post_json "/live_conversations/#{first.id}/turns", role: "user", content: "Good, carry on"
    assert_response :created
    assert_equal 2, second.reload.turns.where(role: %w[user tool]).count

    post_json "/live_conversations/#{first.id}/tool_calls", name: "switch_live_conversation", arguments: "{}", call_id: "c2", reattaches: 1
    assert_equal second.id, response.parsed_body.dig("switched_to", "id")
    assert_equal second, LiveConversation.current
    assert_equal 1, LiveConversation.unfinished.count
  end
end
