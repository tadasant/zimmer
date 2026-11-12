require "test_helper"
require "open3"

# The web half of a truncated tool call. live_voice_controller.js has no browser
# test (a WebRTC call to OpenAI cannot run in CI), so this runs the shipped file
# under Node with the browser stubbed and asserts on what it sends OpenAI.
class LiveVoiceTruncatedToolCallTest < ActiveSupport::TestCase
  HARNESS = Rails.root.join("test/javascript/live_voice_truncated_tool_call.mjs")
  CONTROLLER = Rails.root.join("app/javascript/controllers/live_voice_controller.js")

  def self.scenarios
    @scenarios ||= begin
      output, errors, status = Open3.capture3("node", HARNESS.to_s, CONTROLLER.to_s)
      raise errors unless status.success?

      output.lines.to_h { |line| JSON.parse(line).then { |row| [ row["name"], row ] } }
    end
  end

  def scenario(name) = self.class.scenarios.fetch(name)

  test "a call relayed before its response ended incomplete still gets its follow-up, uncapped" do
    run = scenario("relayed_then_incomplete")

    assert_equal [ "z1" ], run["relayed"]
    assert_equal [ "session.update:inf", "conversation.item.create", "response.create" ], run["sent"]
  end

  test "a result that beats the response's end still gets its follow-up, uncapped" do
    assert_equal [ "conversation.item.create", "session.update:inf", "response.create" ], scenario("result_before_incomplete")["sent"]
  end

  test "a call first seen in an incomplete response's response.done is run, not lost" do
    run = scenario("first_seen_in_incomplete_done")

    assert_equal [ "z1" ], run["relayed"]
    assert_equal [ "session.update:inf", "conversation.item.create", "response.create" ], run["sent"]
  end

  test "a spoken reply cut off with nothing asked for goes back to listening and asks for nothing" do
    run = scenario("speech_only_incomplete")

    assert_equal "listening", run["state"]
    assert_empty run["sent"]
  end

  test "a cap that ran out before a word was said lifts the cap and asks again" do
    assert_equal [ "session.update:inf", "response.create" ], scenario("cut_before_a_word")["sent"]
  end

  test "a later session update keeps the cap lifted" do
    assert_equal "session.update:inf", scenario("later_session_update")["sent"].last
  end

  test "a call cut off before its first character is refused, not run with no arguments" do
    assert_equal [ "{" ], scenario("blank_arguments")["arguments"]
  end

  test "three cuts in a row stop asking and say so, and a filter leaves the cap alone" do
    run = scenario("three_cuts_in_a_row")

    assert_equal 2, run["sent"].count("response.create")
    assert_not_includes run["sent"], "session.update:inf"
    assert_equal "listening", run["state"]
    assert_match(/kept cutting/, scenario("three_cuts_error")["error"])
  end

  test "a response the user talked over still asks for nothing more" do
    assert_equal [ "conversation.item.create" ], scenario("cancelled")["sent"]
  end

  test "a tool call that moved Live Mode sends nothing more and reattaches, keeping mute" do
    run = scenario("switched_mid_call")

    assert_empty run["sent"]
    assert_equal 1, run["bodies"].first["reattaches"]
    started = run["started"].sole
    assert_equal 8, started["next"]["conversationId"]
    assert_equal "/live_conversations/8/client_secret", started["next"]["clientSecretUrl"]
    assert_equal({ "moved" => true, "muted" => true }, started["options"])
  end

  test "a call follows the current conversation, and nothing else" do
    assert_equal [ 8 ], scenario("follows_current")["followed"]
  end

  test "a conversation someone is typing in ends the call instead of turning voice on over them" do
    run = scenario("typed_conversation_ends_the_call")

    assert_match(/typed conversation/, run["hungUp"].first)
    assert_equal true, run["hungUp"].last["keepError"]
  end

  test "the move itself: a new secret for the new conversation, mute kept, the model asked to speak, nothing on the thread" do
    run = scenario("reattach_through_start")

    assert_equal [ "/live_conversations/8/client_secret", "https://openai.test/calls" ], run["requests"]
    assert_equal 8, run["conversation"]
    assert_equal true, run["muted"]
    assert_equal [ "idle", "connecting", "listening" ], run["states"]
    assert_equal [ "conversation.item.create", "response.create" ], run["sent"]
  end

  test "a call that moved speaks first, and the line is not recorded on the thread" do
    run = scenario("speaks_first")

    assert_equal [ "conversation.item.create", "response.create" ], run["sent"]
    assert_empty run["relayed"]
  end

  test "a hang-up the person asked for asks for no reply, and ends the call only once the goodbye has sounded" do
    run = scenario("hang_up_after_goodbye")

    assert_equal 1, run["hangsUp"], "the dock says it can hang up"
    assert_equal [ "conversation.item.create" ], run["sent"]
    assert_equal 0, run["beforeDone"], "not while the response is still running"
    assert_equal 0, run["beforeStopped"], "not while the goodbye is still sounding"
    assert_equal 1, run["ended"]
  end

  test "a hang-up answered with nothing left sounding ends the call at once" do
    run = scenario("hang_up_nothing_sounding")

    assert_equal [ "conversation.item.create" ], run["sent"]
    assert_equal 1, run["ended"]
  end

  test "a hang-up ends the call the way End does, with its cue, and leaves nothing armed" do
    run = scenario("hang_up_through_real_hang_up")

    assert_equal "idle", run["state"]
    assert_equal [ "hung_up" ], run["cues"]
    assert_equal false, run["hangingUp"]
    assert_equal 2, run["generation"]
  end
end
