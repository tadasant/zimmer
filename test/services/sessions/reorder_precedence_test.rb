# frozen_string_literal: true

require "test_helper"

# The midpoint rule behind a drag in the Ranked view, and the nudge that makes
# room for it when there is none.
class Sessions::ReorderPrecedenceTest < ActiveSupport::TestCase
  def spot(precedence)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test",
      scheduling_class: SessionGenesis::SPOT, precedence: precedence)
  end

  test "a drop between two well-separated rows takes the midpoint" do
    above = spot(100)
    below = spot(50)
    moved = spot(1)

    result = Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: above, below: below)

    assert_equal 75, result.precedence
    assert_equal 75, moved.reload.precedence
    assert_equal 100, above.reload.precedence, "an untouched neighbour must not move"
    assert_equal 50, below.reload.precedence
  end

  # The case an integer column cannot answer on its own: there is no value
  # between 21 and 20, so the neighbours are pushed one apart each and the
  # dropped row takes the middle of the gap that opens.
  test "a drop between two adjacent rows nudges the neighbours apart" do
    above = spot(21)
    below = spot(20)
    moved = spot(1)

    result = Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: above, below: below)

    assert_equal 22, above.reload.precedence
    assert_equal 19, below.reload.precedence
    assert_operator result.precedence, :<, above.precedence
    assert_operator result.precedence, :>, below.precedence
  end

  test "a drop between two equal values nudges them apart too" do
    above = spot(12)
    below = spot(12)
    moved = spot(1)

    result = Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: above, below: below)

    assert_equal 13, above.reload.precedence
    assert_equal 11, below.reload.precedence
    assert_equal 12, result.precedence
  end

  # The client applies the returned values optimistically, so every row that
  # moved has to come back — the dragged one and any neighbour nudged aside.
  test "the result names every row whose value changed" do
    above = spot(21)
    below = spot(20)
    moved = spot(1)

    result = Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: above, below: below)

    assert_equal({ above.id => 22, below.id => 19, moved.id => result.precedence },
      result.changes)
  end

  test "a drop at the top clears the row below it by the slot gap" do
    below = spot(40)
    moved = spot(1)

    result = Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: nil, below: below)

    assert_equal 40 + SessionPrecedence::SLOT_GAP, result.precedence
  end

  test "a drop at the bottom sits below the row above it by the slot gap" do
    above = spot(40)
    moved = spot(90)

    result = Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: above, below: nil)

    assert_equal 40 - SessionPrecedence::SLOT_GAP, result.precedence
  end

  test "a drop into an empty queue takes the default" do
    moved = spot(90)

    result = Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: nil, below: nil)

    assert_equal SessionPrecedence::DEFAULT, result.precedence
  end

  # A stale page could name the two neighbours the wrong way round. Read them in
  # the order the data supports rather than computing a midpoint outside the gap.
  test "neighbours sent in the wrong order still produce a value between them" do
    result = Sessions::ReorderPrecedence.call(session: spot(1), actor: :web, above: spot(50), below: spot(100))

    assert_operator result.precedence, :>, 50
    assert_operator result.precedence, :<, 100
  end

  test "refuses to place a session next to itself" do
    session = spot(10)

    assert_raises(Sessions::ReorderPrecedence::Error) do
      Sessions::ReorderPrecedence.call(session: session, actor: :web, above: session, below: nil)
    end
  end

  # --- the log row ------------------------------------------------------------

  test "logs the dragged session's move with its old value and the web actor" do
    moved = spot(1)

    Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: spot(100), below: spot(50))

    assert_equal [ "Precedence set to 75 (was 1) by drag-and-drop in the Ranked view" ],
      moved.logs.where("content LIKE ?", "Precedence set%").pluck(:content)
  end

  test "labels the REST log row" do
    moved = spot(1)

    Sessions::ReorderPrecedence.call(session: moved, actor: :rest, above: spot(100), below: spot(50))

    assert_equal [ "Precedence set to 75 (was 1) by a reorder through the REST API" ],
      moved.logs.where("content LIKE ?", "Precedence set%").pluck(:content)
  end

  # Only the dragged session's own move is logged. A drop back onto the value it
  # already holds still nudges nothing here, and a neighbour nudged aside gets
  # no row of its own.
  test "a drop that leaves the dragged value alone writes no log row" do
    above = spot(100)
    below = spot(50)
    moved = spot(75)

    assert_no_difference -> { Log.count } do
      result = Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: above, below: below)
      assert_empty result.changes
    end
  end

  test "a nudged neighbour gets no log row" do
    above = spot(21)
    below = spot(20)
    moved = spot(1)

    Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: above, below: below)

    assert_equal 22, above.reload.precedence
    assert_empty above.logs.where("content LIKE ?", "Precedence set%")
    assert_empty below.logs.where("content LIKE ?", "Precedence set%")
    assert_equal 1, moved.logs.where("content LIKE ?", "Precedence set%").count
  end

  # The ranks and the log row commit together: a log write that fails takes the
  # dragged row and any nudged neighbour back with it.
  test "a failed log write leaves every rank where it was" do
    above = spot(21)
    below = spot(20)
    moved = spot(1)
    failing = Object.new
    def failing.create!(*) = raise(ActiveRecord::RecordInvalid)

    moved.stub(:logs, failing) do
      assert_raises(ActiveRecord::RecordInvalid) do
        Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: above, below: below)
      end
    end

    assert_equal 1, moved.reload.precedence
    assert_equal 21, above.reload.precedence
    assert_equal 20, below.reload.precedence
  end

  # And the other way round: a rank write that fails leaves no log row.
  test "a failed rank write leaves no log row" do
    moved = spot(1)
    moved.define_singleton_method(:update!) { |*| raise ActiveRecord::RecordInvalid }

    assert_no_difference -> { Log.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        Sessions::ReorderPrecedence.call(session: moved, actor: :web, above: spot(100), below: spot(50))
      end
    end
    assert_equal 1, moved.reload.precedence
  end

  test "an unknown actor writes nothing" do
    moved = spot(1)

    assert_no_difference -> { Log.count } do
      assert_raises(KeyError) do
        Sessions::ReorderPrecedence.call(session: moved, actor: :mcp, above: spot(100), below: spot(50))
      end
    end
    assert_equal 1, moved.reload.precedence
  end
end
