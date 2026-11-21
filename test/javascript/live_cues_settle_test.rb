require "test_helper"
require "open3"

# The web dock's cues wait for the person's turn to really end. Turn detection
# ends a turn on a short pause, and a heard note or thinking pulse there tells
# someone mid-thought they were cut off. This runs the shipped lib/live_cues.js
# (director and player) under Node on a fake clock and AudioContext, and asserts
# on what actually sounded. The iOS twin is LiveCueSettleTests in ios/Tests.
class LiveCuesSettleTest < ActiveSupport::TestCase
  HARNESS = Rails.root.join("test/javascript/live_cues_settle.mjs")
  CUES = Rails.root.join("app/javascript/lib/live_cues.js")

  def self.scenarios
    @scenarios ||= begin
      output, errors, status = Open3.capture3("node", HARNESS.to_s, CUES.to_s)
      raise errors unless status.success?

      output.lines.to_h { |line| JSON.parse(line).then { |row| [ row["name"], row ] } }
    end
  end

  def scenario(name) = self.class.scenarios.fetch(name)

  test "a short pause followed by more speech sounds nothing and never closes the microphone" do
    assert_equal [], scenario("pause_then_more_speech")["sounded"]
    assert_equal 0, scenario("pause_then_more_speech")["micClosings"]
  end

  test "a pause just short of the settle time is still a pause" do
    assert_equal [], scenario("pause_just_short_of_settle")["sounded"]
  end

  test "several short pauses in one long thought sound nothing" do
    assert_equal [], scenario("several_pauses")["sounded"]
  end

  test "a real end of turn sounds heard once the person has been quiet for the settle time, then thinking" do
    row = scenario("real_end_of_turn")
    assert_equal [], row["beforeSettle"]
    assert_equal %w[heard], row["atSettle"]
    assert_equal %w[heard thinking], row["sounded"].first(2)
  end

  test "an answer that starts within the settle time gets no cue" do
    assert_equal [], scenario("quick_answer")["sounded"]
  end

  test "a pause while a tool runs brings the working loop back only after the settle time" do
    row = scenario("tool_running")
    assert_equal %w[working], row["working"]
    assert_equal %w[working], row["afterPause"], "the pause they talked on from sounded nothing"
    assert_operator row["sounded"].count("working"), :>, 1
  end

  test "a tool the model starts right after the stop is committed work and does not wait" do
    assert_equal %w[working], scenario("tool_after_stop")["sounded"]
  end

  test "a stop under a reply does not delay the next response's loop" do
    assert_equal [ { "startLoop" => "thinking" } ], scenario("stop_under_a_reply")["actions"]
  end

  test "a failure held while the person talks waits out the settle time after they stop" do
    assert_equal [], scenario("held_failure")["duringPause"]
    assert_equal [], scenario("held_failure")["sounded"]
    assert_equal [], scenario("held_failure_real_stop")["beforeSettle"]
    assert_equal %w[failed], scenario("held_failure_real_stop")["sounded"]
  end
end
