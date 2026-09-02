# frozen_string_literal: true

require "test_helper"

# Where a session sits in the spot queue, and how it gets there.
class SessionPrecedenceTest < ActiveSupport::TestCase
  def build_session(**attrs)
    Session.create!({ git_root: "https://github.com/test/repo.git", prompt: "Test" }.merge(attrs))
  end

  # --- assignment -------------------------------------------------------------

  test "a session with no parent and no stated rank starts at the default" do
    assert_equal SessionPrecedence::DEFAULT, build_session.precedence
  end

  test "an explicit rank is kept" do
    assert_equal 4200, build_session(precedence: 4200).precedence
  end

  # The rule the MCP descriptions promise: a spawned session sits just above the
  # session that spawned it, so a tree of work stays contiguous instead of the
  # child sinking behind unrelated queued work.
  test "a spawned session lands just above its parent" do
    parent = build_session(precedence: 900)
    child = build_session(parent_session_id: parent.id)

    assert_equal 901, child.precedence
  end

  test "a fork lands just above the session it forked from" do
    origin = build_session(precedence: 60)
    fork = build_session(metadata: { "forked_from_session_id" => origin.id })

    assert_equal 61, fork.precedence
  end

  test "an explicit rank beats inheritance" do
    parent = build_session(precedence: 900)
    child = build_session(parent_session_id: parent.id, precedence: 5)

    assert_equal 5, child.precedence
  end

  # An explicit zero is a choice — "put this at the bottom" — and must not be
  # re-derived from the parent.
  test "an explicit zero is honored rather than re-derived" do
    parent = build_session(precedence: 900)
    child = build_session(parent_session_id: parent.id, precedence: 0)

    assert_equal 0, child.precedence
  end

  # A form's empty field is "say nothing", not an unsaveable NULL on a NOT NULL
  # column.
  test "a blank rank falls back to the default" do
    assert_equal SessionPrecedence::DEFAULT, build_session(precedence: "").precedence
    assert_equal SessionPrecedence::DEFAULT, build_session(precedence: nil).precedence
  end

  # --- validation -------------------------------------------------------------

  test "a rank beyond the accepted range is rejected" do
    session = Session.new(git_root: "https://github.com/test/repo.git", prompt: "Test",
      precedence: SessionPrecedence::MAX + 1)

    assert_not session.valid?
    assert_includes session.errors.full_messages.join, "Precedence"
  end

  # --- ordering ---------------------------------------------------------------

  test "ranked orders highest first, oldest first within a tie" do
    low = build_session(precedence: 10, scheduling_class: SessionGenesis::SPOT)
    high = build_session(precedence: 100, scheduling_class: SessionGenesis::SPOT)
    tie_older = build_session(precedence: 50, scheduling_class: SessionGenesis::SPOT,
      created_at: 2.days.ago)
    tie_newer = build_session(precedence: 50, scheduling_class: SessionGenesis::SPOT,
      created_at: 1.day.ago)

    ordered = Session.where(id: [ low.id, high.id, tie_older.id, tie_newer.id ]).ranked.to_a

    assert_equal [ high, tie_older, tie_newer, low ], ordered
  end

  # --- placing at the head of the queue ---------------------------------------

  test "precedence_above_top_spot clears the highest spot session by the slot gap" do
    build_session(precedence: 70, scheduling_class: SessionGenesis::SPOT)
    build_session(precedence: 12, scheduling_class: SessionGenesis::SPOT)

    assert_equal 70 + SessionPrecedence::SLOT_GAP, Session.precedence_above_top_spot
  end

  # A priority session's rank is carried but not part of the spot queue, so it
  # must not inflate where a demotion lands.
  test "precedence_above_top_spot ignores priority sessions" do
    build_session(precedence: 100_000, scheduling_class: SessionGenesis::PRIORITY)
    build_session(precedence: 30, scheduling_class: SessionGenesis::SPOT)

    assert_equal 30 + SessionPrecedence::SLOT_GAP, Session.precedence_above_top_spot
  end

  # The guarantee has to survive the only path that passes a scope — the demote
  # button, which excludes the session being demoted. Applying the archived
  # exclusion to the default branch alone would let precedence ratchet upward
  # across archive cycles.
  test "precedence_above_top_spot ignores archived sessions in a caller's scope" do
    demoted = build_session(scheduling_class: SessionGenesis::PRIORITY)
    build_session(precedence: 900, scheduling_class: SessionGenesis::SPOT, status: :archived)
    build_session(precedence: 30, scheduling_class: SessionGenesis::SPOT)

    assert_equal 30 + SessionPrecedence::SLOT_GAP,
      Session.precedence_above_top_spot(Session.where.not(id: demoted.id))
  end

  test "precedence_above_top_spot falls back to the default when nothing is queued" do
    assert_equal SessionPrecedence::DEFAULT + SessionPrecedence::SLOT_GAP,
      Session.precedence_above_top_spot
  end

  # --- symbolic placements ------------------------------------------------------

  test "precedence_for_place resolves top_of_spot against the live queue" do
    build_session(precedence: 70, scheduling_class: SessionGenesis::SPOT)

    assert_equal 70 + SessionPrecedence::SLOT_GAP,
      Session.precedence_for_place(SessionPrecedence::PLACE_TOP_OF_SPOT)
  end

  test "precedence_for_place passes a caller's scope through to the placement" do
    excluded = build_session(precedence: 900, scheduling_class: SessionGenesis::SPOT)
    build_session(precedence: 30, scheduling_class: SessionGenesis::SPOT)

    assert_equal 30 + SessionPrecedence::SLOT_GAP,
      Session.precedence_for_place(SessionPrecedence::PLACE_TOP_OF_SPOT, Session.where.not(id: excluded.id))
  end

  test "precedence_for_place rejects a placement it does not know" do
    error = assert_raises(ArgumentError) { Session.precedence_for_place("bottom_of_spot") }

    assert_match(/Unknown precedence placement/, error.message)
  end

  # Every surface validates the argument it accepts against this list, so a
  # placement that is not in it is one no schema will advertise.
  test "PLACES names every placement the surfaces accept" do
    assert_equal [ SessionPrecedence::PLACE_TOP_OF_SPOT ], SessionPrecedence::PLACES
  end
end
