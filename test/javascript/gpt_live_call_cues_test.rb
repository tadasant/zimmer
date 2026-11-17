require "test_helper"
require "open3"

# The web dock's cues on the `gpt_live_claude` engine. A GPT-Live call cannot
# run in CI, so this runs the shipped lib/gpt_live_call.js under Node, its cue
# signals fed to the shipped LiveCueDirector, and asserts on what the person
# would hear. The iOS twin is GptLiveConductorTests in ios/Tests.
class GptLiveCallCuesTest < ActiveSupport::TestCase
  HARNESS = Rails.root.join("test/javascript/gpt_live_call_cues.mjs")
  CALL = Rails.root.join("app/javascript/lib/gpt_live_call.js")
  CUES = Rails.root.join("app/javascript/lib/live_cues.js")

  def self.scenarios
    @scenarios ||= begin
      output, errors, status = Open3.capture3("node", HARNESS.to_s, CALL.to_s, CUES.to_s)
      raise errors unless status.success?

      output.lines.to_h { |line| JSON.parse(line).then { |row| [ row["name"], row["heard"] ] } }
    end
  end

  def heard(name) = self.class.scenarios.fetch(name)

  test "a line gone quiet with no answer begun is heard, then thinking until the answer" do
    assert_equal %w[play:connected stopCues loop:thinking play:heard stopCues], heard("heard_then_answer")
  end

  test "an answer that starts before the line goes quiet gets no heard" do
    assert_equal %w[play:connected stopCues stopCues], heard("quick_answer")
  end

  test "a delegation is the working loop through GPT-Live's filler, then thinking until the answer is said" do
    assert_equal %w[play:connected stopCues loop:working stopCues loop:working stopLoop loop:thinking stopCues], heard("delegation")
  end

  test "a delegation Zimmer could not answer sounds failed" do
    assert_includes heard("delegation_failed"), "play:failed"
    assert_includes heard("delegation_refused"), "play:failed"
  end
end
