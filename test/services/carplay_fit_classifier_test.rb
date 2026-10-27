# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The backfill classifier: one completion over the blurb a session already has,
# writing an `auto` mark at the blurb's line count and leaving the blurb alone.
class CarplayFitClassifierTest < ActiveSupport::TestCase
  class FakeInference
    attr_reader :prompts

    def initialize(answer)
      @answer = answer
      @prompts = []
    end

    def generate(prompt, **)
      @prompts << prompt
      @answer
    end
  end

  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    SessionStatusSummary.any_instance.stubs(:broadcast_panel_replacement)

    @session = Session.create!(
      agent_runtime: "claude_code", status: :needs_input, prompt: "p", title: "AWS Device Farm",
      git_root: "https://github.com/test/repo.git", branch: "main"
    )
  end

  def summary!(text, line_count: 40)
    SessionStatusSummary.create!(session: @session, state: "ready", summary: text, transcript_line_count: line_count, generated_at: Time.current)
  end

  test "writes an automatic mark from the blurb, stamped at the blurb's line count" do
    summary!("When you're at a laptop, do the four AWS and secrets steps listed in the notes.", line_count: 38)
    inference = FakeInference.new("carplay-fit: laptop_only; reason: credential")

    result = CarplayFitClassifier.call(@session, inference_service: inference)

    assert result.applied?
    @session.reload
    assert_equal "laptop_only", @session.carplay_fit
    assert_equal "credential", @session.carplay_fit_reason
    assert_equal "auto", @session.carplay_fit_source
    assert_equal 38, @session.carplay_fit_line_count
    assert_includes inference.prompts.sole, "When you're at a laptop"
    assert_includes inference.prompts.sole, "AWS Device Farm"
    assert_equal "When you're at a laptop, do the four AWS and secrets steps listed in the notes.",
      @session.status_summary.reload.summary, "the blurb is left exactly as it was"
  end

  test "a session with no blurb is skipped, and an answer without the line writes nothing" do
    assert_equal :skipped, CarplayFitClassifier.call(@session, inference_service: FakeInference.new("x")).outcome

    summary!("Merge the PR.")
    assert_equal :failed, CarplayFitClassifier.call(@session.reload, inference_service: FakeInference.new("Not logged in")).outcome
    assert_nil @session.reload.carplay_fit
  end

  test "a standing human mark is kept" do
    summary!("Merge the PR.")
    Sessions::SetCarplayFit.call(session: @session, fit: "laptop_only", source: "human", line_count: 40)

    result = CarplayFitClassifier.call(@session, inference_service: FakeInference.new("carplay-fit: carplay_ok; reason: decision"))

    assert_equal :kept, result.outcome
    assert_equal "laptop_only", @session.reload.carplay_fit
  end
end
