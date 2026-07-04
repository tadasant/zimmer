# frozen_string_literal: true

# Tracks push notifications sent to users about session events.
#
# Notifications are created when push notifications are sent (e.g., when a session
# needs input). They can be marked as:
# - read: User has engaged with the notification (clicked it or marked it read)
# - stale: Session has been actioned (follow-up sent, archived, etc.) making the
#          notification no longer relevant
#
# Stale notifications are "pulled out" of the notification queue and won't appear
# on the /notifications page, preventing users from seeing outdated alerts.
#
# Attributes:
#   session_id        - The session this notification relates to
#   notification_type - Type of notification (e.g., "needs_input")
#   read              - Whether the user has engaged with this notification
#   stale             - Whether the session has been actioned, making this irrelevant
class Notification < ApplicationRecord
  belongs_to :session

  validates :notification_type, presence: true

  # Scopes for common queries
  scope :unread, -> { where(read: false) }
  scope :active, -> { where(stale: false) }
  scope :pending, -> { active.unread }

  # Mark all notifications for a session as stale (user actioned the session)
  # This "pulls out" the notifications so they don't appear in the queue
  #
  # @param session [Session] The session that was actioned
  def self.mark_session_stale(session)
    where(session: session, stale: false).update_all(stale: true)
  end

  # Get count of pending notifications (unread and not stale)
  #
  # @return [Integer] Number of pending notifications
  def self.pending_count
    pending.count
  end

  # Mark this notification as read
  def mark_read!
    update!(read: true)
  end

  # Mark this notification as stale
  def mark_stale!
    update!(stale: true)
  end
end
