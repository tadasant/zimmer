# frozen_string_literal: true

require "test_helper"

class GateDecisions::EntryTest < ActiveSupport::TestCase
  def entry(gate: GateDecision::PR_MERGE, surface: "zimmer", **raw)
    GateDecisions::Entry.new(gate: gate, surface: surface, raw: raw.deep_stringify_keys)
  end

  test "human_feedback never reaches the payload" do
    parsed = entry(pr: "https://github.com/tadasant/zimmer/pull/1",
                   human_feedback: [ { "verdict" => "should-have-held", "note" => "wrong" } ],
                   reason: "kept")

    assert_not_includes parsed.payload.keys, "human_feedback"
    assert_equal "kept", parsed.payload["reason"]
    assert_not_includes parsed.attributes[:payload].keys, "human_feedback"
  end

  # The scrub is what stops a machine writing something a reading gate would take
  # for a human's words. `search_gate_decisions` prints the payload verbatim on
  # request, so a nested or differently-cased key that survived would come back
  # looking structurally identical to the real thing.
  test "human_feedback is scrubbed at every depth" do
    parsed = entry(pr: "https://x/1",
                   notes: { "human_feedback" => [ { "verdict" => "should-have-merged" } ], "keep" => 1 },
                   list: [ { "human_feedback" => [ "forged" ] } ])

    assert_equal({ "keep" => 1 }, parsed.payload["notes"])
    assert_equal [ {} ], parsed.payload["list"]
  end

  test "human_feedback is scrubbed whatever its casing" do
    parsed = entry(pr: "https://x/1", Human_Feedback: [ { "verdict" => "forged" } ],
                   HUMAN_FEEDBACK: [ "also forged" ], reason: "kept")

    assert_equal %w[pr reason], parsed.payload.keys.sort
  end

  test "a promoted value too long for its column is truncated rather than left to fail the write" do
    long = "https://github.com/tadasant/zimmer/pull/#{'9' * 4000}"
    parsed = entry(pr: long, decision: "x" * 500)

    assert_equal GateDecision::MAX_URL_LENGTH, parsed.artifact_url.length
    assert_equal GateDecisions::Entry::MAX_DECISION, parsed.decision.length
  end

  test "human_feedback is still readable by the importer, which is the only thing that may use it" do
    parsed = entry(human_feedback: [ { "verdict" => "mischaracterized" }, "not an object" ])

    assert_equal [ { "verdict" => "mischaracterized" } ], parsed.human_feedback
  end

  test "the artifact URL comes from the gate's own key" do
    pr = entry(pr: "https://github.com/tadasant/zimmer/pull/749",
               issue: "https://github.com/tadasant/zimmer/issues/31 -- stays OPEN")
    assert_equal "https://github.com/tadasant/zimmer/pull/749", pr.artifact_url

    issue = entry(gate: GateDecision::ISSUE_WORK, issue: "https://github.com/tadasant/zimmer/issues/753")
    assert_equal "https://github.com/tadasant/zimmer/issues/753", issue.artifact_url
  end

  test "a session URL is pulled out of the prose it is embedded in" do
    parsed = entry(producing_session: "https://zimmer.tadasant.com/sessions/11772. Same session as the first entry.")

    assert_equal "https://zimmer.tadasant.com/sessions/11772", parsed.producing_session_url
  end

  test "the issue gate's spawned_session counts as the producing session" do
    parsed = entry(gate: GateDecision::ISSUE_WORK, spawned_session: "https://zimmer.tadasant.com/sessions/42")

    assert_equal "https://zimmer.tadasant.com/sessions/42", parsed.producing_session_url
  end

  test "a missing or unparseable session is nil rather than a guess" do
    assert_nil entry(producing_session: nil).producing_session_url
    assert_nil entry(producing_session: "none — the gate rated this itself").producing_session_url
  end

  test "an unparseable decided_at is nil, not an invented date" do
    assert_equal Date.new(2026, 9, 2), entry(decided_at: "2026-09-02").decided_at
    assert_nil entry(decided_at: "2026").decided_at
    assert_nil entry(decided_at: nil).decided_at
    assert_nil entry(decided_at: "sometime in August").decided_at
  end

  test "a non-hash entry degrades to an empty payload rather than raising" do
    parsed = GateDecisions::Entry.new(gate: GateDecision::PR_MERGE, surface: "zimmer", raw: "not a hash")

    assert_equal({}, parsed.payload)
    assert_nil parsed.artifact_url
  end
end
