# frozen_string_literal: true

require "test_helper"

# "Here is the board, top to bottom", applied as one write. Behind the
# `reorder_user_view` MCP tool, which is how the Reprioritize button's session
# rewrites the dashboard's order.
class Sessions::ApplyUserViewOrderTest < ActiveSupport::TestCase
  def setup
    Session.delete_all
  end

  def spot(precedence)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test",
      scheduling_class: SessionGenesis::SPOT, precedence: precedence)
  end

  test "the listed sessions come back in the order given, spaced by GAP" do
    a = spot(1)
    b = spot(2)
    c = spot(3)

    result = Sessions::ApplyUserViewOrder.call(session_ids: [ c.id, a.id, b.id ])

    ranked = Session.where(id: [ a.id, b.id, c.id ]).ranked.pluck(:id)
    assert_equal [ c.id, a.id, b.id ], ranked, "the board reads in exactly the order named"
    assert_equal 3, result.changed_count
    gaps = result.ordered.map(&:last).each_cons(2).map { |high, low| high - low }
    assert_equal [ Sessions::ApplyUserViewOrder::GAP ] * 2, gaps
  end

  # The spacing is not decoration: a human has to be able to drag a row between
  # any two of the agent's choices without the server having to nudge anything.
  test "a dragged row fits between two placed rows without a nudge" do
    a = spot(0)
    b = spot(0)
    mover = spot(0)
    Sessions::ApplyUserViewOrder.call(session_ids: [ a.id, b.id ])

    result = Sessions::ReorderPrecedence.call(session: mover, above: a.reload, below: b.reload)

    assert_equal 1, result.changes.size, "only the dragged row should have been written"
    assert_equal [ a.id, mover.id, b.id ],
      Session.where(id: [ a.id, b.id, mover.id ]).ranked.pluck(:id)
  end

  # A partial order is the scaling story: rank the rows the decision turns on,
  # leave the tail alone — and the tail must end up BELOW them, not interleaved.
  test "unlisted sessions keep their rank and sit below every listed one" do
    untouched = spot(10_000)
    a = spot(1)
    b = spot(2)

    Sessions::ApplyUserViewOrder.call(session_ids: [ b.id, a.id ])

    assert_equal 10_000, untouched.reload.precedence, "an unlisted session is not rewritten"
    assert_equal [ b.id, a.id, untouched.id ], Session.ranked.pluck(:id)
  end

  # The maximum is read live so a board whose top has since been trashed does not
  # keep inflating the scale on every press of the button.
  test "an archived high scorer does not inflate the scale" do
    archived = spot(1_000_000)
    archived.update_column(:status, Session.statuses[:archived])
    a = spot(1)

    result = Sessions::ApplyUserViewOrder.call(session_ids: [ a.id ])

    assert_operator result.ordered.first.last, :<, 1_000_000
  end

  # The button is pressed whenever the board looks wrong, which on a busy day is
  # several times. If the range were measured against the whole table — rows this
  # very call is about to rewrite included — each press would land higher than the
  # last and the scale would inflate for as long as somebody kept pressing.
  test "re-applying the same order is a no-op, not a ratchet" do
    a = spot(1)
    b = spot(2)
    first = Sessions::ApplyUserViewOrder.call(session_ids: [ b.id, a.id ])
    Log.delete_all

    second = Sessions::ApplyUserViewOrder.call(session_ids: [ b.id, a.id ])

    assert_equal 0, second.changed_count
    assert_equal first.ordered, second.ordered
    assert_equal 0, Log.count
  end

  test "the reason travels into each moved session's log" do
    a = spot(1)

    Sessions::ApplyUserViewOrder.call(session_ids: [ a.id ], reason: "green PR blocking three sessions")

    assert_match(/green PR blocking three sessions/, a.logs.last.content)
    assert_match(/placed 1 on the User view/, a.logs.last.content)
  end

  test "an unknown id is refused and nothing is written" do
    a = spot(1)

    error = assert_raises(Sessions::ApplyUserViewOrder::Error) do
      Sessions::ApplyUserViewOrder.call(session_ids: [ a.id, 999_999_999 ])
    end

    assert_match(/999999999/, error.message)
    assert_equal 1, a.reload.precedence, "a rejected call must not half-apply"
  end

  test "a duplicate id is refused" do
    a = spot(1)

    error = assert_raises(Sessions::ApplyUserViewOrder::Error) do
      Sessions::ApplyUserViewOrder.call(session_ids: [ a.id, a.id ])
    end

    assert_match(/Duplicate/, error.message)
  end

  test "an empty list is refused" do
    assert_raises(Sessions::ApplyUserViewOrder::Error) { Sessions::ApplyUserViewOrder.call(session_ids: []) }
  end

  test "more ids than the cap is refused" do
    over = (1..(Sessions::ApplyUserViewOrder::MAX_IDS + 1)).to_a

    error = assert_raises(Sessions::ApplyUserViewOrder::Error) do
      Sessions::ApplyUserViewOrder.call(session_ids: over)
    end

    assert_match(/Too many/, error.message)
  end
end
