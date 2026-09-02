# frozen_string_literal: true

require "test_helper"

class GateDecisions::RecordTest < ActiveSupport::TestCase
  def record(gate: "pr_merge", surface: "zimmer", entry: {}, **options)
    GateDecisions::Record.call(gate: gate, surface: surface, entry: entry,
                               recorded_via: GateDecision::MCP, **options)
  end

  test "promotes the stable fields and keeps the rest verbatim" do
    result = record(entry: {
      "pr" => "https://github.com/tadasant/zimmer/pull/749",
      "title" => "add the Pi coding agent",
      "decided_at" => "2026-09-02",
      "decision" => "auto-merge",
      "producing_session" => "https://zimmer.tadasant.com/sessions/11772. Same session.",
      "hold_tests" => [ "a" ], "disclosures" => { "x" => 1 }
    })

    decision = result.decision
    assert result.created?
    assert_equal "pr_merge", decision.gate
    assert_equal "https://github.com/tadasant/zimmer/pull/749", decision.artifact_url
    assert_equal Date.new(2026, 9, 2), decision.decided_at
    assert_equal "auto-merge", decision.decision
    assert_equal "https://zimmer.tadasant.com/sessions/11772", decision.producing_session_url
    assert_equal [ "a" ], decision.payload["hold_tests"], "unpromoted keys survive untouched"
    assert_equal({ "x" => 1 }, decision.payload["disclosures"])
    assert_equal "https://github.com/tadasant/zimmer/pull/749", decision.payload["pr"],
                 "promotion copies rather than moves, so the entry stays whole"
  end

  test "human_feedback is dropped on the way in and writes no feedback row" do
    result = record(entry: { "pr" => "https://x/1", "human_feedback" => [ { "verdict" => "should-have-merged" } ] })

    assert_not_includes result.decision.payload.keys, "human_feedback"
    assert_empty result.decision.feedbacks
    assert_equal 0, GateDecisionFeedback.count
  end

  test "the writing session comes from the caller's boundary, never from the entry" do
    session = sessions(:archived)
    result = record(entry: { "pr" => "https://x/1", "writing_session_id" => 999_999,
                             "writing_session" => "https://zimmer.tadasant.com/sessions/999999" },
                    writing_session: session)

    assert_equal session.id, result.decision.writing_session_id
  end

  test "gate and surface are normalized so one surface does not become two" do
    result = record(gate: "PR-MERGE", surface: "Strad-Production", entry: { "pr" => "https://x/1" })

    assert_equal GateDecision::PR_MERGE, result.decision.gate
    assert_equal "strad_production", result.decision.surface
  end

  test "an unknown gate is refused and nothing is written" do
    error = assert_raises(GateDecisions::Record::InvalidEntry) { record(gate: "vibes") }

    assert_match(/gate must be one of/, error.message)
    assert_equal 0, GateDecision.count
  end

  test "a blank surface is refused" do
    assert_raises(GateDecisions::Record::InvalidEntry) { record(surface: "  ") }
  end

  test "an entry that is not an object is refused" do
    assert_raises(GateDecisions::Record::InvalidEntry) { record(entry: [ 1, 2 ]) }
  end
end
