# frozen_string_literal: true

require "test_helper"

class NotificationTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:active_session)
  end

  test "valid notification" do
    notification = Notification.new(
      session: @session,
      notification_type: "needs_input"
    )
    assert notification.valid?
  end

  test "requires session" do
    notification = Notification.new(notification_type: "needs_input")
    assert_not notification.valid?
    assert_includes notification.errors[:session], "must exist"
  end

  test "requires notification_type" do
    notification = Notification.new(session: @session)
    assert_not notification.valid?
    assert_includes notification.errors[:notification_type], "can't be blank"
  end

  test "defaults read to false" do
    notification = Notification.create!(session: @session, notification_type: "needs_input")
    assert_equal false, notification.read
  end

  test "defaults stale to false" do
    notification = Notification.create!(session: @session, notification_type: "needs_input")
    assert_equal false, notification.stale
  end

  test "unread scope" do
    read = Notification.create!(session: @session, notification_type: "needs_input", read: true)
    unread = Notification.create!(session: @session, notification_type: "needs_input", read: false)

    assert_includes Notification.unread, unread
    assert_not_includes Notification.unread, read
  end

  test "active scope" do
    stale = Notification.create!(session: @session, notification_type: "needs_input", stale: true)
    active = Notification.create!(session: @session, notification_type: "needs_input", stale: false)

    assert_includes Notification.active, active
    assert_not_includes Notification.active, stale
  end

  test "pending scope" do
    # pending = active AND unread
    stale_unread = Notification.create!(session: @session, notification_type: "needs_input", stale: true, read: false)
    active_read = Notification.create!(session: @session, notification_type: "needs_input", stale: false, read: true)
    pending = Notification.create!(session: @session, notification_type: "needs_input", stale: false, read: false)

    assert_includes Notification.pending, pending
    assert_not_includes Notification.pending, stale_unread
    assert_not_includes Notification.pending, active_read
  end

  test "mark_session_stale marks all non-stale notifications for session as stale" do
    notification1 = Notification.create!(session: @session, notification_type: "needs_input", stale: false)
    notification2 = Notification.create!(session: @session, notification_type: "session_failed", stale: false)
    already_stale = Notification.create!(session: @session, notification_type: "needs_input", stale: true)

    # Create notification for different session
    other_session = sessions(:running)
    other_notification = Notification.create!(session: other_session, notification_type: "needs_input", stale: false)

    Notification.mark_session_stale(@session)

    notification1.reload
    notification2.reload
    already_stale.reload
    other_notification.reload

    assert notification1.stale?, "notification1 should be stale"
    assert notification2.stale?, "notification2 should be stale"
    assert already_stale.stale?, "already_stale should still be stale"
    assert_not other_notification.stale?, "other_notification should not be affected"
  end

  test "pending_count returns count of pending notifications" do
    # Clean up any existing notifications
    Notification.destroy_all

    # Create some notifications
    Notification.create!(session: @session, notification_type: "needs_input", stale: false, read: false)
    Notification.create!(session: @session, notification_type: "needs_input", stale: false, read: false)
    Notification.create!(session: @session, notification_type: "needs_input", stale: true, read: false)
    Notification.create!(session: @session, notification_type: "needs_input", stale: false, read: true)

    assert_equal 2, Notification.pending_count
  end

  test "mark_read! marks notification as read" do
    notification = Notification.create!(session: @session, notification_type: "needs_input")
    assert_not notification.read?

    notification.mark_read!

    assert notification.read?
  end

  test "mark_stale! marks notification as stale" do
    notification = Notification.create!(session: @session, notification_type: "needs_input")
    assert_not notification.stale?

    notification.mark_stale!

    assert notification.stale?
  end
end
