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
end
