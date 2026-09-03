require "test_helper"
require "mocha/minitest"

# Board visibility: the session's second axis, and the one that decides nothing.
#
# Two things are worth proving here above all else. First, that an expired snooze
# reads as visible without anything having written to the row — that is what makes
# a snooze end by itself. Second, that the scope and the row-level predicate always
# agree, since the dashboard filters with one and renders badges with the other.
class SessionVisibilityTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    }.merge(attrs))
  end

  test "a new session is visible with no snooze time" do
    session = make_session

    assert_equal SessionVisibility::VISIBLE, session.visibility
    assert_nil session.snoozed_until
    assert session.board_visible?
    assert_nil session.visibility_summary
  end

  test "an unknown visibility is rejected" do
    session = make_session
    session.visibility = "somewhen"

    assert_not session.valid?
    assert_includes session.errors.full_messages.join, "not a valid visibility"
  end

  test "a hidden session is off the board and has no end time" do
    session = make_session(visibility: SessionVisibility::HIDDEN)

    assert_not session.board_visible?
    assert_not session.snooze_active?
    assert_equal SessionVisibility::HIDDEN, session.effective_visibility
    assert_equal "Hidden from the board", session.visibility_summary
  end

  test "a live snooze is off the board and reports when it ends" do
    at = 2.days.from_now
    session = make_session(visibility: SessionVisibility::SNOOZED, snoozed_until: at)

    assert_not session.board_visible?
    assert session.snooze_active?
    assert_equal SessionVisibility::SNOOZED, session.effective_visibility
    assert_includes session.visibility_summary, "Snoozed until"
  end

  # The heart of the derived design: no job ran, no row was written, and the
  # session is simply back.
  test "an expired snooze reads as visible without the row changing" do
    session = make_session(visibility: SessionVisibility::SNOOZED, snoozed_until: 1.hour.ago)

    assert session.board_visible?
    assert_not session.snooze_active?
    assert_equal SessionVisibility::VISIBLE, session.effective_visibility
    assert_nil session.visibility_summary
    # The stored choice is untouched — only its reading has changed.
    assert_equal SessionVisibility::SNOOZED, session.reload.visibility
  end

  test "board_visible scope matches the row predicate for every case" do
    visible = make_session
    hidden = make_session(visibility: SessionVisibility::HIDDEN)
    snoozed = make_session(visibility: SessionVisibility::SNOOZED, snoozed_until: 3.days.from_now)
    expired = make_session(visibility: SessionVisibility::SNOOZED, snoozed_until: 5.minutes.ago)

    mine = [ visible, hidden, snoozed, expired ].map(&:id)
    on_board = Session.where(id: mine).board_visible.pluck(:id)
    off_board = Session.where(id: mine).board_hidden.pluck(:id)

    assert_equal [ visible.id, expired.id ].sort, on_board.sort
    assert_equal [ hidden.id, snoozed.id ].sort, off_board.sort

    [ visible, hidden, snoozed, expired ].each do |session|
      assert_equal session.board_visible?, on_board.include?(session.id),
        "scope and predicate disagree about session #{session.id}"
    end
  end

  test "the two scopes are exact complements" do
    make_session
    make_session(visibility: SessionVisibility::HIDDEN)
    make_session(visibility: SessionVisibility::SNOOZED, snoozed_until: 1.day.from_now)
    make_session(visibility: SessionVisibility::SNOOZED, snoozed_until: 1.day.ago)
    # Fixture sessions count too — every row in the table has to land in exactly
    # one of the two scopes, which is the property being asserted.

    assert_equal Session.count, Session.board_visible.count + Session.board_hidden.count
    assert_empty Session.board_visible.where(id: Session.board_hidden.select(:id))
  end

  # A row that Sessions::SetVisibility cannot produce, but which the scopes must
  # still classify one way rather than falling through both.
  test "a snoozed row with no time is treated as off the board" do
    session = make_session(visibility: SessionVisibility::SNOOZED)

    assert_not session.board_visible?
    assert_includes Session.board_hidden.pluck(:id), session.id
    assert_not_includes Session.board_visible.pluck(:id), session.id
    assert_equal SessionVisibility::SNOOZED, session.effective_visibility
  end

  test "the scopes take an explicit now" do
    session = make_session(visibility: SessionVisibility::SNOOZED, snoozed_until: 1.hour.from_now)

    assert_includes Session.board_hidden.pluck(:id), session.id
    assert_includes Session.board_visible(2.hours.from_now).pluck(:id), session.id
    assert session.board_visible?(2.hours.from_now)
  end
end
