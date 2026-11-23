# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Sessions::BoardV2Test < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.delete_all
    @infra = BoardCategory.create!(name: "Infra")
    @ui = BoardCategory.create!(name: "UI")
  end

  def make(title, category: nil, touched: nil, status: :needs_input)
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p", title: title, status: status)
    session.merge_metadata!("last_user_activity_at" => touched.iso8601) if touched
    session.update_columns(board_category_id: category&.id)
    session
  end

  test "groups by category in position order, Uncategorized apart, most recently touched first inside each" do
    old = make("old infra", category: @infra, touched: 3.hours.ago)
    fresh = make("fresh infra", category: @infra, touched: 5.minutes.ago)
    loose = make("loose")
    ui = make("ui", category: @ui, touched: 1.hour.ago)

    board = Sessions::BoardV2.build(scope: Session.all, limit: 50)

    assert_equal [ loose ], board.uncategorized
    assert_equal [ @infra, @ui ], board.sections.map(&:category)
    assert_equal [ fresh, old ], board.sections.first.sessions
    assert_equal [ ui ], board.sections.last.sessions
    assert_equal 4, board.session_count
  end

  test "touched means a person's last activity, not updated_at" do
    chatty = make("chatty agent", category: @infra, touched: 2.hours.ago)
    chatty.update_columns(updated_at: Time.current)
    human = make("human touched", category: @infra, touched: 10.minutes.ago)
    human.update_columns(updated_at: 3.days.ago)

    board = Sessions::BoardV2.build(scope: Session.all, limit: 50)

    assert_equal [ human, chatty ], board.sections.first.sessions
  end

  test "an empty category still gets a section" do
    board = Sessions::BoardV2.build(scope: Session.all, limit: 50)
    assert_equal [ [], [] ], board.sections.map(&:sessions)
  end

  test "a snoozed or backlogged category is tucked away with a count, and its sessions do not render" do
    make("in infra", category: @infra)
    make("also infra", category: @infra)
    shown = make("in ui", category: @ui)
    @infra.update!(visibility: SessionVisibility::SNOOZED, snoozed_until: 1.day.from_now)

    board = Sessions::BoardV2.build(scope: Session.all, limit: 50)

    assert_equal [ @ui ], board.sections.map(&:category)
    assert_equal [ shown ], board.sections.first.sessions
    assert_equal [ [ @infra, 2 ] ], board.tucked.map { |t| [ t.category, t.count ] }
  end

  test "an expired category snooze is simply back" do
    make("in infra", category: @infra)
    @infra.update_columns(visibility: SessionVisibility::SNOOZED, snoozed_until: 1.minute.ago)

    board = Sessions::BoardV2.build(scope: Session.all, limit: 50)

    assert_empty board.tucked
    assert_equal 1, board.sections.first.sessions.size
  end

  test "follows whatever the scope already filtered" do
    make("waiting one", category: @infra, status: :waiting)
    kept = make("needs input", category: @infra)

    board = Sessions::BoardV2.build(scope: Session.where(status: :needs_input), limit: 50)

    assert_equal [ kept ], board.sections.first.sessions
  end

  test "the cap drops the least recently touched and says so" do
    newest = make("newest", category: @ui, touched: 1.minute.ago)
    make("oldest", category: @infra, touched: 5.days.ago)

    board = Sessions::BoardV2.build(scope: Session.all, limit: 1)

    assert board.truncated
    assert_equal [ newest ], board.sections.flat_map(&:sessions)
  end

  test "a tucked-away category names the matching sessions it holds" do
    @infra.update!(visibility: "backlogged")
    held = make("held", category: @infra)
    make("filtered out", category: @infra, status: :waiting)
    make("on the board", category: @ui)

    board = Sessions::BoardV2.build(scope: Session.where(status: :needs_input).order(:id), limit: 50)

    assert_equal [ [ @infra, [ held.id ], 1 ] ], board.tucked.map { |t| [ t.category, t.session_ids, t.count ] }
  end
end
