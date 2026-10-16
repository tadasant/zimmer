require "test_helper"

module Supervisor
  class LiveConversationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @conversation = create_live_conversation(mode: "voice", instructions_source: "example/live@abc:AGENTS.md")
      @turn = @conversation.turns.create!(role: "tool", tool_name: "zimmer", call_id: "call_s1", tool_arguments: { "tool" => "get_session" }, tool_output: "ok")
    end

    test "lists and shows live conversations and their turns, read-only" do
      get supervisor_live_conversations_url
      assert_response :success
      assert_match "live-voice", response.body

      get supervisor_live_conversation_url(@conversation)
      assert_response :success
      assert_match "example/live@abc:AGENTS.md", response.body

      get supervisor_live_conversation_turn_url(@turn)
      assert_response :success
      assert_match "call_s1", response.body

      assert_raises(NameError) { edit_supervisor_live_conversation_url(@conversation) }
    end
  end
end
