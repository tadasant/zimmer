# frozen_string_literal: true

require "test_helper"

class NotificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @session = sessions(:active_session)
    # Clean up any existing notifications
    Notification.destroy_all
  end

  test "index shows active notifications" do
    active = Notification.create!(session: @session, notification_type: "needs_input", stale: false)
    stale = Notification.create!(session: @session, notification_type: "needs_input", stale: true)

    get notifications_path

    assert_response :success
    assert_select "div#notification_#{active.id}"
    assert_select "div#notification_#{stale.id}", count: 0
  end

  test "index shows empty state when no notifications" do
    get notifications_path

    assert_response :success
    assert_select "h3", text: "No notifications"
  end

  test "badge returns pending count" do
    Notification.create!(session: @session, notification_type: "needs_input", stale: false, read: false)
    Notification.create!(session: @session, notification_type: "needs_input", stale: false, read: false)
    Notification.create!(session: @session, notification_type: "needs_input", stale: true, read: false)

    get badge_notifications_path

    assert_response :success
    # Badge should show count of 2 (only pending = active + unread)
    assert_select "span.bg-red-500", text: "2"
  end

  test "badge shows no count when no pending notifications" do
    # Create only stale or read notifications
    Notification.create!(session: @session, notification_type: "needs_input", stale: true)
    Notification.create!(session: @session, notification_type: "needs_input", read: true)

    get badge_notifications_path

    assert_response :success
    # No badge should be displayed
    assert_select "span.bg-red-500", count: 0
  end

  test "mark_read marks notification as read" do
    notification = Notification.create!(session: @session, notification_type: "needs_input", read: false)

    patch mark_read_notification_path(notification)

    assert_response :redirect
    notification.reload
    assert notification.read?
  end

  test "mark_read with turbo_stream" do
    notification = Notification.create!(session: @session, notification_type: "needs_input", read: false)

    patch mark_read_notification_path(notification), as: :turbo_stream

    assert_response :success
    notification.reload
    assert notification.read?

    # Verify turbo_stream response includes both notification and badge updates
    assert_match "notification_#{notification.id}", response.body
    assert_match "notification_badge", response.body
  end

  test "mark_all_read marks all active notifications as read" do
    n1 = Notification.create!(session: @session, notification_type: "needs_input", stale: false, read: false)
    n2 = Notification.create!(session: @session, notification_type: "needs_input", stale: false, read: false)
    stale = Notification.create!(session: @session, notification_type: "needs_input", stale: true, read: false)

    patch mark_all_read_notifications_path

    assert_response :redirect
    n1.reload
    n2.reload
    stale.reload

    assert n1.read?
    assert n2.read?
    # Stale notifications shouldn't be affected (they're not in active scope)
    assert_not stale.read?
  end

  test "click marks notification as read and redirects to session" do
    notification = Notification.create!(session: @session, notification_type: "needs_input", read: false)

    get click_notification_path(notification)

    assert_redirected_to session_path(@session)
    notification.reload
    assert notification.read?
  end

  test "click does not error if notification already read" do
    notification = Notification.create!(session: @session, notification_type: "needs_input", read: true)

    get click_notification_path(notification)

    assert_redirected_to session_path(@session)
    notification.reload
    assert notification.read?
  end

  test "dismiss deletes read notification" do
    notification = Notification.create!(session: @session, notification_type: "needs_input", read: true)

    delete dismiss_notification_path(notification)

    assert_response :redirect
    assert_not Notification.exists?(notification.id)
  end

  test "dismiss with turbo_stream removes notification from page" do
    notification = Notification.create!(session: @session, notification_type: "needs_input", read: true)

    delete dismiss_notification_path(notification), as: :turbo_stream

    assert_response :success
    assert_not Notification.exists?(notification.id)

    # Verify turbo_stream response removes the notification and updates badge
    assert_match "notification_#{notification.id}", response.body
    assert_match "notification_badge", response.body
  end

  test "dismiss prevents deletion of unread notification" do
    notification = Notification.create!(session: @session, notification_type: "needs_input", read: false)

    delete dismiss_notification_path(notification)

    assert_response :redirect
    # Notification should still exist
    assert Notification.exists?(notification.id)
  end

  test "dismiss unread notification with turbo_stream re-renders row" do
    notification = Notification.create!(session: @session, notification_type: "needs_input", read: false)

    delete dismiss_notification_path(notification), as: :turbo_stream

    assert_response :success
    # Notification should still exist
    assert Notification.exists?(notification.id)
    # Verify turbo_stream response replaces the notification (re-renders row)
    assert_match "notification_#{notification.id}", response.body
  end

  test "dismiss_all_read deletes all read notifications" do
    read1 = Notification.create!(session: @session, notification_type: "needs_input", read: true)
    read2 = Notification.create!(session: @session, notification_type: "needs_input", read: true)
    unread = Notification.create!(session: @session, notification_type: "needs_input", read: false)
    stale_read = Notification.create!(session: @session, notification_type: "needs_input", read: true, stale: true)

    delete dismiss_all_read_notifications_path

    assert_response :redirect
    # Read notifications should be deleted
    assert_not Notification.exists?(read1.id)
    assert_not Notification.exists?(read2.id)
    # Unread notifications should remain
    assert Notification.exists?(unread.id)
    # Stale read notifications should also remain (not in active scope)
    assert Notification.exists?(stale_read.id)
  end
end
