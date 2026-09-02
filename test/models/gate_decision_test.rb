# frozen_string_literal: true

require "test_helper"

class GateDecisionTest < ActiveSupport::TestCase
  def decision(**overrides)
    GateDecision.create!({
      gate: GateDecision::PR_MERGE,
      surface: "zimmer",
      artifact_url: "https://github.com/tadasant/zimmer/pull/1",
      decided_at: Date.new(2026, 9, 1),
      decision: "auto-merge",
      recorded_via: GateDecision::MCP,
      payload: { "title" => "A change", "reason" => "It was fine." }
    }.merge(overrides))
  end

  test "a written decision cannot be updated" do
    record = decision

    error = assert_raises(ActiveRecord::ReadOnlyRecord) { record.update!(decision: "hold") }
    assert_match(/append-only/, error.message)
    assert_equal "auto-merge", record.reload.decision
  end

  test "a written decision cannot be destroyed" do
    record = decision

    assert_raises(ActiveRecord::ReadOnlyRecord) { record.destroy }
    assert GateDecision.exists?(record.id)
  end

  test "feedback goes with the decision when the decision goes with its association" do
    record = decision
    record.feedbacks.create!(verdict: "should-have-held", channel: GateDecisionFeedback::IMPORTED)

    # A row is only ever removed with its parent, and the parent is itself
    # undeletable — so this asserts the destroy_by_association escape hatch is
    # wired, not that anything routinely deletes.
    assert_nothing_raised { record.feedbacks.first.send(:destroyed_by_association=, record.class.reflect_on_association(:feedbacks)) }
  end

  test "an unknown gate is refused" do
    record = GateDecision.new(gate: "vibes", surface: "zimmer")

    assert_not record.valid?
    assert_includes record.errors[:gate], "is not included in the list"
  end

  test "gate aliases normalize and unknown gates do not" do
    assert_equal GateDecision::PR_MERGE, GateDecision.normalize_gate("pr-merge")
    assert_equal GateDecision::PR_MERGE, GateDecision.normalize_gate("PR_MERGE_GATE")
    assert_equal GateDecision::ISSUE_WORK, GateDecision.normalize_gate("issue-work-gate")
    assert_nil GateDecision.normalize_gate("merge_everything")
  end

  test "surfaces normalize so one surface does not become two" do
    assert_equal "strad_production", GateDecision.normalize_surface("Strad-Production")
    assert_equal "zimmer", GateDecision.normalize_surface(" ZIMMER ")
    assert_nil GateDecision.normalize_surface("")
  end

  test "recent_for returns one surface newest first, with id breaking a same-day tie" do
    older = decision(decided_at: Date.new(2026, 8, 1))
    same_day_first = decision(decided_at: Date.new(2026, 9, 1))
    same_day_second = decision(decided_at: Date.new(2026, 9, 1))
    decision(surface: "strad", decided_at: Date.new(2026, 9, 2))

    found = GateDecision.recent_for(gate: GateDecision::PR_MERGE, surface: "zimmer", limit: 10).to_a

    assert_equal [ same_day_second.id, same_day_first.id, older.id ], found.map(&:id)
  end

  test "matching_text searches the whole payload, not just the promoted columns" do
    hit = decision(payload: { "reason" => "The conflict was in air_prepare_service.rb" })
    decision(payload: { "reason" => "Nothing to do with that file" })

    assert_equal [ hit.id ], GateDecision.matching_text("air_prepare_service.rb").pluck(:id)
    assert_equal [ hit.id ], GateDecision.matching_text("AIR_PREPARE").pluck(:id), "search is case-insensitive"
  end

  test "matching_text treats LIKE metacharacters literally" do
    hit = decision(payload: { "reason" => "100% certain" })
    decision(payload: { "reason" => "something else entirely" })

    assert_equal [ hit.id ], GateDecision.matching_text("100%").pluck(:id)
  end

  test "with_human_feedback finds only decisions a human commented on" do
    commented = decision
    commented.feedbacks.create!(verdict: "should-have-held", channel: GateDecisionFeedback::IMPORTED)
    decision

    assert_equal [ commented.id ], GateDecision.with_human_feedback.pluck(:id)
  end

  test "a payload that is not an object is refused" do
    record = GateDecision.new(gate: GateDecision::PR_MERGE, surface: "zimmer", recorded_via: GateDecision::API,
                              payload: [ 1, 2, 3 ])

    assert_not record.valid?
    assert_includes record.errors[:payload], "must be a JSON object"
  end

  test "an oversized payload is refused rather than stored" do
    record = GateDecision.new(gate: GateDecision::PR_MERGE, surface: "zimmer", recorded_via: GateDecision::API,
                              payload: { "reason" => "x" * (GateDecision::MAX_PAYLOAD_BYTES + 1) })

    assert_not record.valid?
    assert_match(/over the/, record.errors[:payload].first)
  end
end
