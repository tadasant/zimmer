# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests for SessionsController notification marking behavior
#
# When a user deliberately visits a session page (HTML request), any
# unread notifications for that session should be marked as read.
# This implements "click to view marks as read" behavior.
class SessionsControllerNotificationsTest < ActionDispatch::IntegrationTest
  def setup
    # Stub Turbo Stream broadcasting to avoid missing partial errors in tests
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    # Stub BroadcastService to avoid ActionCable issues in tests
    BroadcastService.any_instance.stubs(:notification_badge)

    @session = sessions(:active_session)
    # Clean up existing notifications for this session (delete_all for performance since no callbacks needed)
    @session.notifications.delete_all
  end

  def teardown
    # Clean up stubs to prevent leakage between tests
    Mocha::Mockery.instance.teardown
  end

  test "viewing session marks unread notifications as read on HTML request" do
    # Create unread notifications for this session
    notification1 = Notification.create!(
      session: @session,
      notification_type: "needs_input",
      read: false,
      stale: false
    )
    notification2 = Notification.create!(
      session: @session,
      notification_type: "session_failed",
      read: false,
      stale: false
    )

    # Visit the session page (HTML request)
    get session_path(@session)

    assert_response :success

    # Both notifications should be marked as read
    notification1.reload
    notification2.reload
    assert notification1.read?, "Expected notification 1 to be marked as read"
    assert notification2.read?, "Expected notification 2 to be marked as read"
  end

  test "viewing session does not affect stale notifications" do
    # Create a stale notification (shouldn't be affected)
    stale_notification = Notification.create!(
      session: @session,
      notification_type: "needs_input",
      read: false,
      stale: true
    )

    get session_path(@session)

    assert_response :success

    # Stale notification should remain unread (not in pending scope)
    stale_notification.reload
    assert_not stale_notification.read?, "Expected stale notification to remain unread"
  end

  test "viewing session does not affect already read notifications" do
    # Create already read notification
    read_notification = Notification.create!(
      session: @session,
      notification_type: "needs_input",
      read: true,
      stale: false
    )

    get session_path(@session)

    assert_response :success

    # Should still be read (idempotent)
    read_notification.reload
    assert read_notification.read?
  end

  test "viewing session does not affect notifications for other sessions" do
    # Create a notification for a different session
    other_session = sessions(:waiting)
    other_notification = Notification.create!(
      session: other_session,
      notification_type: "needs_input",
      read: false,
      stale: false
    )

    # Visit the original session
    get session_path(@session)

    assert_response :success

    # Other session's notification should remain unread
    other_notification.reload
    assert_not other_notification.read?, "Expected other session's notification to remain unread"
  end

  test "viewing session broadcasts updated badge count" do
    # Create an unread notification
    Notification.create!(
      session: @session,
      notification_type: "needs_input",
      read: false,
      stale: false
    )

    # Expect BroadcastService to be called with the new pending count
    broadcast_service = mock
    BroadcastService.stubs(:new).returns(broadcast_service)
    broadcast_service.expects(:notification_badge).with(0).once

    get session_path(@session)

    assert_response :success
  end

  test "viewing session with no unread notifications does not broadcast" do
    # No notifications exist

    # Create mock that should NOT receive notification_badge call
    broadcast_service = mock
    BroadcastService.stubs(:new).returns(broadcast_service)
    broadcast_service.expects(:notification_badge).never

    get session_path(@session)

    assert_response :success
  end

  test "viewing session as JSON does not mark notifications as read" do
    # Create unread notification
    notification = Notification.create!(
      session: @session,
      notification_type: "needs_input",
      read: false,
      stale: false
    )

    # Request with JSON format (like an API call)
    get session_path(@session), as: :json

    # JSON requests should not mark notifications as read
    # (The show action may not respond to JSON, which is fine)
    notification.reload
    assert_not notification.read?, "Expected notification to remain unread on JSON request"
  end

  test "viewing session via slug marks notifications as read" do
    # Create a session with a slug
    @session.update!(slug: "test-session-slug")

    notification = Notification.create!(
      session: @session,
      notification_type: "needs_input",
      read: false,
      stale: false
    )

    # Visit using the slug
    get session_path("test-session-slug")

    assert_response :success
    notification.reload
    assert notification.read?, "Expected notification to be marked as read when visiting via slug"
  end

  test "pending count reflects notifications marked as read" do
    # Create notifications for multiple sessions
    notification1 = Notification.create!(
      session: @session,
      notification_type: "needs_input",
      read: false,
      stale: false
    )
    other_session = sessions(:waiting)
    notification2 = Notification.create!(
      session: other_session,
      notification_type: "needs_input",
      read: false,
      stale: false
    )

    # Initial pending count should be 2
    assert_equal 2, Notification.pending_count

    # Visit the first session
    get session_path(@session)

    assert_response :success

    # Pending count should now be 1 (only other session's notification)
    assert_equal 1, Notification.pending_count
  end
end
