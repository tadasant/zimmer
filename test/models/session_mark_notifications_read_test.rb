# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# A person opening a session reads its notifications — from the dashboard and the app alike.
class SessionMarkNotificationsReadTest < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    @session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "p", status: :needs_input)
    @other = Session.create!(git_root: "https://github.com/t/r.git", prompt: "p", status: :needs_input)
  end

  test "marks this session's pending notifications read, bumps them, and broadcasts the badge" do
    mine = Notification.create!(session: @session, notification_type: "needs_input", updated_at: 1.day.ago)
    stale = Notification.create!(session: @session, notification_type: "session_failed", stale: true)
    theirs = Notification.create!(session: @other, notification_type: "needs_input")
    broadcast = mock
    broadcast.expects(:notification_badge).once
    BroadcastService.stubs(:new).returns(broadcast)

    assert_equal 1, @session.mark_notifications_read!

    assert mine.reload.read
    assert_operator mine.updated_at, :>, 1.minute.ago
    assert_not stale.reload.read, "a stale one is not pending, so it is left alone"
    assert_not theirs.reload.read, "another session's are left alone"
  end

  test "marks nothing and broadcasts nothing when there is nothing unread" do
    BroadcastService.expects(:new).never

    assert_equal 0, @session.mark_notifications_read!
  end
end
