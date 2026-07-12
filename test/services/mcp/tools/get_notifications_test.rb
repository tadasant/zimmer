# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::GetNotificationsTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetNotifications.new(context: Mcp::Context.new(tool_groups: "notifications"))
    Notification.delete_all
    @session = sessions(:active_session)
    @unread = Notification.create!(session: @session, notification_type: "needs_input", read: false, stale: false)
    @read = Notification.create!(session: @session, notification_type: "session_failed", read: true, stale: false)
    @stale = Notification.create!(session: @session, notification_type: "needs_input", read: false, stale: true)
  end

  test "badge_only returns the pending count" do
    result = @tool.call("badge_only" => true)

    assert_includes result, "## Notification Badge"
    assert_includes result, "**Pending notifications:** 1"
  end

  test "id returns a single notification with its session" do
    result = @tool.call("id" => @unread.id)

    assert_includes result, "## Notification ##{@unread.id}"
    assert_includes result, "- **Type:** needs_input"
    assert_includes result, "- **Read:** No"
    assert_includes result, "- **Session ID:** #{@session.id}"
    assert_includes result, "- **Session Status:** #{@session.status}"
  end

  test "id raises when the notification does not exist" do
    error = assert_raises(Mcp::ToolError) { @tool.call("id" => 999_999) }

    assert_equal "Notification not found: 999999", error.message
  end

  test "list returns active notifications with pagination header" do
    result = @tool.call({})

    assert_includes result, "## Notifications (2 total, page 1 of 1)"
    assert_includes result, "**##{@unread.id}** [unread] needs_input"
    assert_includes result, "**##{@read.id}** [read] session_failed"
    refute_includes result, "**##{@stale.id}**"
  end

  test "list filters by status and paginates" do
    result = @tool.call("status" => "unread", "page" => 1, "per_page" => 1)

    assert_includes result, "## Notifications (1 total, page 1 of 1)"
    assert_includes result, "**##{@unread.id}** [unread]"
    refute_includes result, "**##{@read.id}**"
  end

  test "list reports an empty inbox" do
    Notification.delete_all

    assert_equal "## Notifications\n\nNo notifications found.", @tool.call({})
  end
end
