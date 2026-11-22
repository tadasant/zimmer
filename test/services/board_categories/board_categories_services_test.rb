# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# BoardCategories::Reorder / Assign / SetVisibility — the writes Your board v2
# and `manage_board_categories` share.
class BoardCategoriesServicesTest < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    @a = BoardCategory.create!(name: "A")
    @b = BoardCategory.create!(name: "B")
    @c = BoardCategory.create!(name: "C")
  end

  test "reorder writes the named order and keeps the rest below it" do
    BoardCategories::Reorder.call(ids: [ @c.id, @a.id ])

    assert_equal [ @c, @a, @b ], BoardCategory.ordered.to_a
  end

  test "reorder refuses unknown ids and duplicates, writing nothing" do
    assert_raises(BoardCategories::Reorder::Error) { BoardCategories::Reorder.call(ids: [ @a.id, 999_999 ]) }
    assert_raises(BoardCategories::Reorder::Error) { BoardCategories::Reorder.call(ids: [ @a.id, @a.id ]) }
    assert_equal [ @a, @b, @c ], BoardCategory.ordered.to_a
  end

  test "assign puts a session in a category and takes it out again, without touching updated_at" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p", title: "s")
    session.update_columns(updated_at: 2.days.ago)
    before = session.reload.updated_at

    BoardCategories::Assign.call(session: session, category_id: @b.id)
    assert_equal @b.id, session.reload.board_category_id
    assert_equal before, session.updated_at

    BoardCategories::Assign.call(session: session, category_id: nil)
    assert_nil session.reload.board_category_id
  end

  test "assign refuses a category that does not exist" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p", title: "s")
    assert_raises(BoardCategories::Assign::Error) { BoardCategories::Assign.call(session: session, category_id: 999_999) }
  end

  test "set_visibility snoozes in the caller's zone, backlogs, and puts back" do
    tomorrow = 1.day.from_now.to_date
    BoardCategories::SetVisibility.call(category: @a, visibility: "snoozed",
      snoozed_until: "#{tomorrow.iso8601}T09:00:00", timezone: "America/New_York")
    assert_equal ActiveSupport::TimeZone["America/New_York"].parse("#{tomorrow.iso8601}T09:00:00"), @a.reload.snoozed_until

    BoardCategories::SetVisibility.call(category: @a, visibility: "backlogged")
    assert @a.reload.backlogged?
    assert_nil @a.snoozed_until

    BoardCategories::SetVisibility.call(category: @a, visibility: "visible")
    assert @a.reload.board_visible?
  end

  test "set_visibility refuses hidden, a past snooze, and never writes the category's sessions" do
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p", title: "s")
    session.update_columns(board_category_id: @a.id)

    assert_raises(Sessions::SetVisibility::Error) { BoardCategories::SetVisibility.call(category: @a, visibility: "hidden") }
    assert_raises(Sessions::SetVisibility::Error) do
      BoardCategories::SetVisibility.call(category: @a, visibility: "snoozed", snoozed_until: 1.day.ago)
    end

    BoardCategories::SetVisibility.call(category: @a, visibility: "backlogged")
    assert_equal SessionVisibility::VISIBLE, session.reload.visibility
  end
end
