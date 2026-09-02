# frozen_string_literal: true

require "test_helper"

class GateDecisions::FiltersTest < ActiveSupport::TestCase
  def decision(**overrides)
    GateDecision.create!({
      gate: GateDecision::PR_MERGE, surface: "zimmer", recorded_via: GateDecision::IMPORT,
      artifact_url: "https://github.com/tadasant/zimmer/pull/#{SecureRandom.hex(3)}",
      decided_at: Date.new(2026, 8, 15), decision: "auto-merge",
      payload: { "reason" => "fine" }
    }.merge(overrides))
  end

  test "filters compose and the result is newest first" do
    older = decision(decided_at: Date.new(2026, 8, 1))
    newer = decision(decided_at: Date.new(2026, 8, 20))
    decision(gate: GateDecision::ISSUE_WORK, decided_at: Date.new(2026, 8, 25))
    decision(surface: "strad", decided_at: Date.new(2026, 8, 25))

    ids = GateDecisions::Filters.new("gate" => "pr_merge", "surface" => "zimmer").scope.pluck(:id)

    assert_equal [ newer.id, older.id ], ids
  end

  test "decision and artifact_url match exactly" do
    held = decision(decision: "hold")
    decision(decision: "auto-merge")

    assert_equal [ held.id ], GateDecisions::Filters.new("decision" => "hold").scope.pluck(:id)
    assert_empty GateDecisions::Filters.new("decision" => "held").scope.pluck(:id)
    assert_equal [ held.id ], GateDecisions::Filters.new("artifact_url" => held.artifact_url).scope.pluck(:id)
  end

  test "a date window is inclusive at both ends" do
    inside = decision(decided_at: Date.new(2026, 8, 1))
    also_inside = decision(decided_at: Date.new(2026, 8, 31))
    decision(decided_at: Date.new(2026, 7, 31))
    decision(decided_at: Date.new(2026, 9, 1))

    ids = GateDecisions::Filters.new("from" => "2026-08-01", "to" => "2026-08-31").scope.pluck(:id)

    assert_equal [ also_inside.id, inside.id ], ids
  end

  test "with_human_feedback narrows to the rare high-signal rows" do
    commented = decision
    commented.feedbacks.create!(verdict: "should-have-held", channel: GateDecisionFeedback::IMPORTED)
    decision

    assert_equal [ commented.id ],
                 GateDecisions::Filters.new("with_human_feedback" => "true").scope.pluck(:id)
  end

  test "an unknown gate is an error, not an empty ledger" do
    error = assert_raises(GateDecisions::Filters::InvalidFilter) { GateDecisions::Filters.new("gate" => "vibes") }

    assert_match(/Unknown gate/, error.message)
  end

  test "an unparseable date is an error, not a silently ignored filter" do
    assert_raises(GateDecisions::Filters::InvalidFilter) { GateDecisions::Filters.new("from" => "last tuesday") }
  end

  test "limit defaults, clamps to the maximum, and rejects nonsense" do
    assert_equal GateDecisions::Filters::DEFAULT_LIMIT, GateDecisions::Filters.new({}).limit
    assert_equal GateDecisions::Filters::MAX_LIMIT, GateDecisions::Filters.new("limit" => 5_000).limit
    assert_equal GateDecisions::Filters::DEFAULT_LIMIT, GateDecisions::Filters.new("limit" => -3).limit
    assert_equal 7, GateDecisions::Filters.new("limit" => "7").limit
  end
end
