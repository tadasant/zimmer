# frozen_string_literal: true

require "test_helper"

class OutcomeAnalyses::SegmentTreeTest < ActiveSupport::TestCase
  def segment(id:, outcome: "Success", explanation: "Went fine.", children: [], trigger_kind: "New",
              trigger_source: "user", goal_kind: "Action", goal_text: "Do the thing", meta: {})
    {
      "id" => id,
      "trigger" => { "kind" => trigger_kind, "source" => trigger_source },
      "goal" => { "text" => goal_text, "kind" => goal_kind },
      "outcome" => { "kind" => outcome, "explanation" => explanation },
      "meta" => meta,
      "children" => children
    }
  end

  test "normalizes a well-formed tree and drops unknown keys" do
    tree = segment(id: "S0", children: [
      segment(id: "S0.0", outcome: "Failure", explanation: "Broke.").merge("skill_recommendations" => [ "nope" ])
    ])

    normalized = OutcomeAnalyses::SegmentTree.normalize!(tree)

    assert_equal "S0", normalized["id"]
    assert_equal %w[id trigger goal outcome meta children], normalized.keys
    # The phase-3 analyzer fields are out of scope, so they are dropped rather
    # than stored — the schema is the contract, not a suggestion.
    refute normalized["children"].first.key?("skill_recommendations")
  end

  test "accepts symbol keys" do
    tree = { id: "S0", trigger: { kind: "New", source: "user" }, goal: { text: "x", kind: "Plan" },
             outcome: { kind: "Success", explanation: "ok" }, meta: {}, children: [] }

    assert_equal "S0", OutcomeAnalyses::SegmentTree.normalize!(tree)["id"]
  end

  test "rejects ids that do not match depth-first position" do
    tree = segment(id: "S0", children: [ segment(id: "S0.7") ])

    error = assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) { OutcomeAnalyses::SegmentTree.normalize!(tree) }
    assert_match(/S0.0.*S0.7.*S0\.0/m, error.message)
  end

  test "rejects a non-Segment root" do
    assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) { OutcomeAnalyses::SegmentTree.normalize!("S0") }
  end

  test "requires an explanation on Success, not only on Failure" do
    tree = segment(id: "S0", outcome: "Success", explanation: "  ")

    error = assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) { OutcomeAnalyses::SegmentTree.normalize!(tree) }
    assert_match(/explanation is required \(on Success as well as Failure\)/, error.message)
  end

  test "caps the explanation so it stays a tooltip" do
    tree = segment(id: "S0", explanation: "y" * (OutcomeAnalyses::SegmentTree::EXPLANATION_MAX + 1))

    error = assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) { OutcomeAnalyses::SegmentTree.normalize!(tree) }
    assert_match(/max #{OutcomeAnalyses::SegmentTree::EXPLANATION_MAX}/, error.message)
  end

  test "rejects unknown enum values and names every one of them at once" do
    tree = segment(id: "S0", trigger_kind: "Nope", trigger_source: "martian", goal_kind: "Doing", outcome: "Maybe")

    error = assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) { OutcomeAnalyses::SegmentTree.normalize!(tree) }
    assert_equal 4, error.errors.size, error.errors.inspect
  end

  test "rejects a Correction with no prior sibling to correct" do
    tree = segment(id: "S0", children: [ segment(id: "S0.0", trigger_kind: "Correction") ])

    error = assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) { OutcomeAnalyses::SegmentTree.normalize!(tree) }
    assert_match(/no prior sibling to correct/, error.message)
  end

  test "allows a Correction that follows a sibling" do
    tree = segment(id: "S0", children: [
      segment(id: "S0.0", outcome: "Failure", explanation: "Missed."),
      segment(id: "S0.1", trigger_kind: "Correction")
    ])

    assert_equal "Correction", OutcomeAnalyses::SegmentTree.normalize!(tree).dig("children", 1, "trigger", "kind")
  end

  test "requires goal text" do
    tree = segment(id: "S0", goal_text: "")

    assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) { OutcomeAnalyses::SegmentTree.normalize!(tree) }
  end

  test "normalizes meta, nulling what it cannot read rather than guessing" do
    tree = segment(id: "S0", meta: { "event_range" => %w[e1 e9], "wall_clock_s" => "12.5",
                                     "tokens_in" => "300", "tokens_out" => nil, "model" => "opus" })

    meta = OutcomeAnalyses::SegmentTree.normalize!(tree)["meta"]

    assert_equal %w[e1 e9], meta["event_range"]
    assert_in_delta 12.5, meta["wall_clock_s"]
    assert_equal 300, meta["tokens_in"]
    assert_nil meta["tokens_out"]
    assert_equal "opus", meta["model"]
  end

  test "rejects a malformed event_range" do
    tree = segment(id: "S0", meta: { "event_range" => [ "only-one" ] })

    error = assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) { OutcomeAnalyses::SegmentTree.normalize!(tree) }
    assert_match(/event_range must be a \[start, end\] pair/, error.message)
  end

  test "rejects a tree deeper than the structural ceiling" do
    deepest = segment(id: "S0")
    node = deepest
    (OutcomeAnalyses::SegmentTree::MAX_DEPTH + 1).times do |i|
      child = segment(id: "#{node['id']}.0")
      node["children"] = [ child ]
      node = child
    end

    error = assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) { OutcomeAnalyses::SegmentTree.normalize!(deepest) }
    assert_match(/maximum nesting depth/, error.message)
  end

  test "summarize counts segments, failures and depth without propagating outcomes" do
    tree = segment(id: "S0", outcome: "Success", children: [
      segment(id: "S0.0", outcome: "Failure", explanation: "Broke."),
      segment(id: "S0.1", children: [ segment(id: "S0.1.0", outcome: "Failure", explanation: "Also broke.") ])
    ])

    summary = OutcomeAnalyses::SegmentTree.summarize(OutcomeAnalyses::SegmentTree.normalize!(tree))

    assert_equal 4, summary.segment_count
    assert_equal 2, summary.failure_segment_count
    assert_equal 2, summary.success_segment_count
    assert_equal 3, summary.max_depth
    # The whole point: two failed children under a Success root leave the root a
    # Success. Outcome is local to the goal.
    assert_equal "Success", summary.root_outcome
  end

  test "caps meta strings so a bounded node count is also a bounded payload" do
    tree = segment(id: "S0", meta: { "model" => "m" * 5_000, "event_range" => [ "e" * 5_000, "f" ] })

    meta = OutcomeAnalyses::SegmentTree.normalize!(tree)["meta"]

    assert_equal OutcomeAnalyses::SegmentTree::META_STRING_MAX, meta["model"].length
    assert_equal OutcomeAnalyses::SegmentTree::META_STRING_MAX, meta["event_range"].first.length
  end

  test "drops a non-scalar meta value rather than storing its inspect output" do
    tree = segment(id: "S0", meta: { "model" => { "a" => 1 } })

    assert_nil OutcomeAnalyses::SegmentTree.normalize!(tree)["meta"]["model"]
  end

  test "reports enough errors to fix the tree, not all of them" do
    children = Array.new(200) { |i| segment(id: "wrong-#{i}", goal_text: "") }
    tree = segment(id: "S0", children: children)

    error = assert_raises(OutcomeAnalyses::SegmentTree::InvalidTree) { OutcomeAnalyses::SegmentTree.normalize!(tree) }

    assert_equal OutcomeAnalyses::SegmentTree::MAX_REPORTED_ERRORS + 1, error.errors.size
    assert_match(/and \d+ more problems/, error.errors.last)
  end

  test "each_segment walks depth-first in id order" do
    tree = OutcomeAnalyses::SegmentTree.normalize!(segment(id: "S0", children: [
      segment(id: "S0.0", children: [ segment(id: "S0.0.0") ]),
      segment(id: "S0.1")
    ]))

    ids = []
    OutcomeAnalyses::SegmentTree.each_segment(tree) { |node, _depth| ids << node["id"] }

    assert_equal %w[S0 S0.0 S0.0.0 S0.1], ids
  end
end
