# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::ActionNotificationTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::ActionNotification.new(context: Mcp::Context.new(tool_groups: "notifications"))
    Notification.delete_all
    @session = sessions(:active_session)
    @unread = Notification.create!(session: @session, notification_type: "needs_input", read: false, stale: false)
    @read = Notification.create!(session: @session, notification_type: "session_failed", read: true, stale: false)
  end

  test "mark_read marks a single notification as read" do
    result = @tool.call("action" => "mark_read", "id" => @unread.id)

    assert_includes result, "## Notification Marked Read"
    assert_includes result, "- **ID:** #{@unread.id}"
    assert_includes result, "- **Type:** needs_input"
    assert @unread.reload.read
  end

  test "mark_read requires an id" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "mark_read") }

    assert_equal '"id" is required for the "mark_read" action.', error.message
  end

  test "mark_all_read marks every active notification" do
    result = @tool.call("action" => "mark_all_read")

    assert_includes result, "## All Notifications Marked Read"
    assert_includes result, "- **Marked:** 1"
    assert_includes result, "- **Remaining Pending:** 0"
    assert @unread.reload.read
  end

  test "dismiss deletes a read notification" do
    result = @tool.call("action" => "dismiss", "id" => @read.id)

    assert_includes result, "## Notification Dismissed"
    assert_includes result, "Notification #{@read.id} has been deleted."
    assert_nil Notification.find_by(id: @read.id)
  end

  test "dismiss refuses an unread notification" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "dismiss", "id" => @unread.id) }

    assert_equal "Cannot dismiss unread notification", error.message
    assert Notification.exists?(@unread.id)
  end

  test "dismiss_all_read deletes only read notifications" do
    result = @tool.call("action" => "dismiss_all_read")

    assert_includes result, "## Read Notifications Dismissed"
    assert_includes result, "- **Dismissed:** 1"
    assert_includes result, "- **Remaining Pending:** 1"
    assert Notification.exists?(@unread.id)
    assert_nil Notification.find_by(id: @read.id)
  end

  test "unknown action raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "explode") }

    assert_includes error.message, 'Unknown action "explode"'
  end

  test "missing action raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call({}) }

    assert_equal "Missing required parameter: action", error.message
  end
end
