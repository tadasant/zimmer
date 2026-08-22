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

    result = Sessions::ReorderPrecedence.call(session: moved, above: above, below: below)

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

    result = Sessions::ReorderPrecedence.call(session: moved, above: above, below: below)

    assert_equal 22, above.reload.precedence
    assert_equal 19, below.reload.precedence
    assert_operator result.precedence, :<, above.precedence
    assert_operator result.precedence, :>, below.precedence
  end

  test "a drop between two equal values nudges them apart too" do
    above = spot(12)
    below = spot(12)
    moved = spot(1)

    result = Sessions::ReorderPrecedence.call(session: moved, above: above, below: below)

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

    result = Sessions::ReorderPrecedence.call(session: moved, above: above, below: below)

    assert_equal({ above.id => 22, below.id => 19, moved.id => result.precedence },
      result.changes)
  end

  test "a drop at the top clears the row below it by the slot gap" do
    below = spot(40)
    moved = spot(1)

    result = Sessions::ReorderPrecedence.call(session: moved, above: nil, below: below)

    assert_equal 40 + SessionPrecedence::SLOT_GAP, result.precedence
  end

  test "a drop at the bottom sits below the row above it by the slot gap" do
    above = spot(40)
    moved = spot(90)

    result = Sessions::ReorderPrecedence.call(session: moved, above: above, below: nil)

    assert_equal 40 - SessionPrecedence::SLOT_GAP, result.precedence
  end

  test "a drop into an empty queue takes the default" do
    moved = spot(90)

    result = Sessions::ReorderPrecedence.call(session: moved, above: nil, below: nil)

    assert_equal SessionPrecedence::DEFAULT, result.precedence
  end

  # A stale page could name the two neighbours the wrong way round. Read them in
  # the order the data supports rather than computing a midpoint outside the gap.
  test "neighbours sent in the wrong order still produce a value between them" do
    result = Sessions::ReorderPrecedence.call(session: spot(1), above: spot(50), below: spot(100))

    assert_operator result.precedence, :>, 50
    assert_operator result.precedence, :<, 100
  end

  test "refuses to place a session next to itself" do
    session = spot(10)

    assert_raises(Sessions::ReorderPrecedence::Error) do
      Sessions::ReorderPrecedence.call(session: session, above: session, below: nil)
    end
  end
end
