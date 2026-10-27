# frozen_string_literal: true

require "test_helper"

# Which sessions a live conversation is about: read off its tool turns, the
# most recently named first, for the call screen in the car.
class LiveConversationReferencedSessionsTest < ActiveSupport::TestCase
  setup do
    stub_live_root
    @conversation = create_live_conversation(mode: "voice")
  end

  test "ids come from the gateway call's arguments and from the output, newest turn first, each once" do
    tool_turn(arguments: { "tool" => "quick_router", "arguments" => { "prompt" => "look into it" } },
              output: "## Quick Router session started\n\n- **ID:** 1101\n- **URL:** https://zimmer.example.com/sessions/1101\n")
    tool_turn(arguments: { "tool" => "get_session", "arguments" => { "id" => 1038 } }, output: "## Session: Merge?\n- **ID:** 1038")
    tool_turn(arguments: { "tool" => "action_session", "arguments" => { "session_id" => "1101", "action" => "follow_up" } }, output: "Sent. See session #1035 too.")
    @conversation.turns.create!(role: "user", source: "spoken", content: "session #9999 is not a tool turn")

    assert_equal [ 1101, 1035, 1038 ], @conversation.referenced_session_ids
    assert_equal [ 1101, 1035 ], @conversation.referenced_session_ids(limit: 2)
  end

  test "a conversation with no tool turns, or turns naming nothing, references nothing" do
    assert_equal [], @conversation.referenced_session_ids
    tool_turn(arguments: { "name" => "test-clock" }, output: "enabled")
    assert_equal [], @conversation.referenced_session_ids
  end

  test "argument ids are read only when they are numbers, under the gateway's nesting or flat" do
    assert_equal [ 7 ], LiveConversation.session_ids_in_arguments({ "arguments" => { "session_id" => 7 } })
    assert_equal [ 7, 8 ], LiveConversation.session_ids_in_arguments({ "session_ids" => [ 7, "8", "x" ] })
    assert_equal [], LiveConversation.session_ids_in_arguments({ "arguments" => { "id" => "abc" } })
    assert_equal [], LiveConversation.session_ids_in_arguments(nil)
    assert_equal [ 1101, 1038, 1035 ], LiveConversation.session_ids_in_text("- **ID:** 1101\nsee /sessions/1038 and session #1035, and /sessions/1101 again")
  end

  private

  def tool_turn(arguments:, output:)
    @conversation.turns.create!(role: "tool", tool_name: "zimmer", call_id: SecureRandom.hex(4), tool_arguments: arguments, tool_output: output)
  end
end
