# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class BoardCategoryTest < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  test "a new category goes to the bottom" do
    first = BoardCategory.create!(name: "First")
    second = BoardCategory.create!(name: "Second")

    assert_operator second.position, :>, first.position
    assert_equal [ first, second ], BoardCategory.ordered.to_a
  end

  test "names are required, squished, capped and unique regardless of case" do
    assert_not BoardCategory.new(name: "  ").valid?
    assert_not BoardCategory.new(name: "x" * (BoardCategory::NAME_MAX_LENGTH + 1)).valid?
    assert_equal "Infra work", BoardCategory.create!(name: "  Infra   work ").name
    assert_not BoardCategory.new(name: "INFRA WORK").valid?
  end

  test "a category is snoozed or backlogged, never hidden, and a snooze needs an end time" do
    category = BoardCategory.create!(name: "Ops")

    assert_not category.update(visibility: SessionVisibility::HIDDEN)
    assert_not category.update(visibility: SessionVisibility::SNOOZED, snoozed_until: nil)
    assert category.update(visibility: SessionVisibility::BACKLOGGED)
  end

  test "a snooze ends by being read, like a session's" do
    category = BoardCategory.create!(name: "Later", visibility: SessionVisibility::SNOOZED, snoozed_until: 1.hour.from_now)
    assert_not category.board_visible?
    assert category.board_visible?(2.hours.from_now)
  end

  test "deleting a category leaves its sessions in Uncategorized" do
    category = BoardCategory.create!(name: "Doomed")
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p", title: "kept")
    session.update_columns(board_category_id: category.id)

    category.destroy!

    assert Session.exists?(session.id)
    assert_nil session.reload.board_category_id
  end
end
