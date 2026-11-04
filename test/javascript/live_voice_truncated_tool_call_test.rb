require "test_helper"
require "open3"

# The web half of a truncated tool call. live_voice_controller.js has no browser
# test (a WebRTC call to OpenAI cannot run in CI), so this runs the shipped file
# under Node with the browser stubbed and asserts on what it sends OpenAI.
class LiveVoiceTruncatedToolCallTest < ActiveSupport::TestCase
  HARNESS = Rails.root.join("test/javascript/live_voice_truncated_tool_call.mjs")
  CONTROLLER = Rails.root.join("app/javascript/controllers/live_voice_controller.js")

  setup do
    output, status = Open3.capture2e("node", HARNESS.to_s, CONTROLLER.to_s)
    assert status.success?, output
    @scenarios = output.lines.to_h { |line| JSON.parse(line).then { |row| [ row["name"], row ] } }
  end

  test "a call relayed before its response ended incomplete still gets its follow-up, uncapped" do
    scenario = @scenarios.fetch("relayed_then_incomplete")

    assert_equal [ "z1" ], scenario["relayed"]
    assert_equal [ "session.update:inf", "conversation.item.create", "response.create" ], scenario["sent"]
  end

  test "a call first seen in an incomplete response's response.done is run, not lost" do
    scenario = @scenarios.fetch("first_seen_in_incomplete_done")

    assert_equal [ "z1" ], scenario["relayed"]
    assert_equal [ "session.update:inf", "conversation.item.create", "response.create" ], scenario["sent"]
  end

  test "a spoken reply cut off with nothing asked for goes back to listening and asks for nothing" do
    scenario = @scenarios.fetch("speech_only_incomplete")

    assert_equal "listening", scenario["state"]
    assert_empty scenario["sent"]
  end

  test "a response the user talked over still asks for nothing more" do
    assert_equal [ "conversation.item.create" ], @scenarios.fetch("cancelled")["sent"]
  end
end
