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

      output.lines.to_h { |line| JSON.parse(line).then { |row| [ row["name"], row ] } }
    end
  end

  def heard(name) = self.class.scenarios.fetch(name).fetch("heard")

  def closed?(name) = self.class.scenarios.fetch(name).fetch("closed")

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
    assert_equal %w[play:connected loop:working stopLoop loop:thinking play:failed], heard("delegation_failed")
    assert_equal %w[play:connected loop:working stopLoop loop:thinking play:failed], heard("delegation_refused")
  end

  test "two delegations keep working until both are back" do
    assert_equal %w[play:connected loop:working | stopLoop loop:thinking], heard("two_delegations")
  end

  test "a stray GPT-Live error while Claude works sounds nothing, and the delegation's failure still does" do
    assert_equal %w[play:connected loop:working | stopLoop loop:thinking play:failed], heard("error_while_working")
  end

  test "thinking that GPT-Live never answers goes back to listening without failed" do
    assert_equal %w[play:connected stopCues loop:thinking play:heard | stopLoop], heard("thinking_gives_up")
  end

  test "a closing call makes no more cues" do
    assert_equal %w[play:connected], heard("closing")
  end

  # Live conversation 38: "let's hang up now", "Okay, hanging up. Bye!", and the
  # call stayed open, because GPT-Live answered without delegating the hang-up.
  test "a goodbye to the person's own hang-up ends the call once it has been said" do
    assert_equal %w[play:connected stopCues stopCues |], heard("goodbye_without_delegating")
    assert closed?("goodbye_without_delegating")
  end

  test "a goodbye the person did not ask for, or a question about hanging up, leaves the call open" do
    assert_not closed?("goodbye_not_asked")
    assert_not closed?("how_to_hang_up")
  end

  test "a goodbye said over a running hang-up delegation waits for the backend's own goodbye" do
    assert_includes heard("goodbye_over_a_delegation"), "|"
    assert_not_includes heard("goodbye_over_a_delegation"), "closed-early"
    assert closed?("goodbye_over_a_delegation")
  end

  test "the hang-up rule needs the person to ask and the answer to say goodbye" do
    assert_equal [ true, true, true, true, true, false, false, false, false, false, false ], heard("ends_the_call")
  end
end
