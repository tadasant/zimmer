# frozen_string_literal: true

require "test_helper"

class OutcomeAnalyses::FlamegraphTest < ActiveSupport::TestCase
  def node(id, outcome: "Success", children: [])
    {
      "id" => id, "trigger" => { "kind" => "New", "source" => "agent" },
      "goal" => { "text" => "Goal #{id}", "kind" => "Action" },
      "outcome" => { "kind" => outcome, "explanation" => "because" },
      "meta" => { "model" => "opus" }, "children" => children
    }
  end

  test "the root spans the full width" do
    flame = OutcomeAnalyses::Flamegraph.new(node("S0"))

    assert_equal 1, flame.cells.size
    assert_in_delta 0.0, flame.cells.first.left
    assert_in_delta 100.0, flame.cells.first.width
    assert_equal 0, flame.depth
  end

  test "children partition the parent's width by subtree size" do
    tree = node("S0", children: [
      node("S0.0", children: [ node("S0.0.0"), node("S0.0.1") ]), # subtree of 3
      node("S0.1") # subtree of 1
    ])

    flame = OutcomeAnalyses::Flamegraph.new(tree)
    by_id = flame.cells.index_by(&:id)

    assert_in_delta 75.0, by_id["S0.0"].width
    assert_in_delta 25.0, by_id["S0.1"].width
    assert_in_delta 0.0, by_id["S0.0"].left
    assert_in_delta 75.0, by_id["S0.1"].left
    # Siblings tile the parent exactly.
    assert_in_delta 100.0, by_id["S0.1"].left + by_id["S0.1"].width
  end

  test "depth becomes the row and failures are flagged for coloring" do
    flame = OutcomeAnalyses::Flamegraph.new(node("S0", children: [ node("S0.0", outcome: "Failure") ]))
    by_id = flame.cells.index_by(&:id)

    assert_equal 0, by_id["S0"].depth
    assert_equal 1, by_id["S0.0"].depth
    assert by_id["S0.0"].failure?
    refute by_id["S0"].failure?
    assert_equal 1, flame.depth
  end

  test "slivers still render but are not labeled" do
    children = Array.new(50) { |i| node("S0.#{i}") }
    flame = OutcomeAnalyses::Flamegraph.new(node("S0", children: children))

    assert_equal 51, flame.cells.size
    assert flame.cells.first.labeled?, "the root is wide enough for its label"
    refute flame.cells.last.labeled?, "a 2%-wide cell has no room for text"
  end

  test "carries the tooltip payload on every cell" do
    cell = OutcomeAnalyses::Flamegraph.new(node("S0", outcome: "Failure")).cells.first

    assert_equal "because", cell.explanation
    assert_equal "Goal S0", cell.goal_text
    assert_equal "Action", cell.goal_kind
    assert_equal "New", cell.trigger_kind
    assert_equal "agent", cell.trigger_source
    assert_equal "opus", cell.model
  end

  test "handles a wide tree without quadratic subtree walking" do
    # 200 siblings each with 5 children: the naive layout recomputes every
    # sibling's subtree size once per sibling.
    children = Array.new(200) { |i| node("S0.#{i}", children: Array.new(5) { |j| node("S0.#{i}.#{j}") }) }
    flame = nil

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    flame = OutcomeAnalyses::Flamegraph.new(node("S0", children: children))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 1201, flame.cells.size
    assert_operator elapsed, :<, 2.0, "flamegraph layout should stay linear in segment count"
  end
end
