# frozen_string_literal: true

require "test_helper"
require "open3"

# Work coming back from the background during a web call. A voice call cannot run
# in CI, so this runs the shipped modules under Node and asserts on what they
# claim from Zimmer and send to the voice model. The iOS twin is
# LiveBackgroundResultsTests in ios/Tests.
class LiveBackgroundResultsJavascriptTest < ActiveSupport::TestCase
  def self.scenarios
    @scenarios ||= begin
      output, errors, status = Open3.capture3(
        "node", Rails.root.join("test/javascript/live_background_results.mjs").to_s,
        Rails.root.join("app/javascript/lib/live_background_results.js").to_s, Rails.root.join("app/javascript/lib/gpt_live_call.js").to_s
      )
      raise errors unless status.success?

      output.lines.to_h { |line| JSON.parse(line).then { |row| [ row["name"], row["value"] ] } }
    end
  end

  def scenario(name) = self.class.scenarios.fetch(name)

  test "a lost answer is claimed again unchanged, and a result is handed over once" do
    value = scenario("lost_then_once")
    assert_equal [ "It finished." ], value["said"]
    assert_equal %w[call-1234:1 call-1234:1 call-1234:2], value["claims"].map(&:last)
    assert_equal [ "/live_conversations/7/background_results" ], value["claims"].map(&:first).uniq
  end

  test "Zimmer is told a result was handed over until it has heard" do
    assert_equal [ [ 1 ], [ 1 ] ], scenario("reported_until_heard")
  end

  test "nothing is claimed while something is being said, heard or run" do
    assert_equal({ "claimedWhileBusy" => 0, "said" => [ "It finished." ] }, scenario("only_while_idle"))
  end

  test "a result that could not be sent is sent on the next look" do
    assert_equal({ "said" => [ "It finished." ], "claims" => 1 }, scenario("kept_until_sent"))
  end

  test "GPT-Live takes it as quiet context, only while idle" do
    value = scenario("gpt_live")
    assert_equal [ false, true, false ], value["states"]
    event = value["sent"].sole
    assert_equal "session.thinking.append", event["type"]
    assert_nil event["delegation_id"]
    assert_equal "It finished.", event["content"]
  end
end
