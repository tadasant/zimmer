# frozen_string_literal: true

# Controller for managing notifications
#
# Notifications are created when push notifications are sent and track
# whether the user has engaged with them. This controller provides:
# - Index page showing non-stale notifications
# - Actions to mark notifications as read
# - Badge endpoint for showing unread count on the homepage
class NotificationsController < ApplicationController
  # GET /notifications
  # Show all active (non-stale) notifications, ordered by most recent first
  def index
    @notifications = Notification.active
                                  .includes(:session)
                                  .order(created_at: :desc)
                                  .limit(100)
  end

  # GET /notifications/badge
  # Return just the badge partial for async loading via Turbo Frame
  def badge
    @pending_count = Notification.pending_count
    render partial: "notification_badge", locals: { pending_count: @pending_count }
  end

  # GET /notifications/:id/click
  # Mark notification as read and redirect to the session
  # This is used when clicking a notification row on the /notifications page
  def click
    notification = Notification.find(params[:id])
    notification.mark_read!

    # Broadcast badge update to all pages showing the notification badge
    BroadcastService.new.notification_badge(Notification.pending_count)

    redirect_to notification.session
  end

  # PATCH /notifications/:id/mark_read
  # Mark a single notification as read
  def mark_read
    notification = Notification.find(params[:id])
    notification.mark_read!

    # Broadcast badge update to all pages showing the notification badge
    BroadcastService.new.notification_badge(Notification.pending_count)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "notification_#{notification.id}",
            partial: "notification_row",
            locals: { notification: notification }
          ),
          turbo_stream.replace(
            "notification_badge",
            partial: "notification_badge",
            locals: { pending_count: Notification.pending_count }
          )
        ]
      end
      format.html { redirect_to notifications_path, notice: "Notification marked as read" }
    end
  end

  # PATCH /notifications/mark_all_read
  # Mark all active notifications as read
  def mark_all_read
    Notification.active.unread.update_all(read: true)

    # Broadcast badge update to all pages showing the notification badge
    BroadcastService.new.notification_badge(Notification.pending_count)

    # Redirect for both formats - turbo_stream will auto-follow the redirect
    redirect_to notifications_path, notice: "All notifications marked as read"
  end

  # DELETE /notifications/:id/dismiss
  # Dismiss (delete) a single notification - only allowed if already read
  def dismiss
    notification = Notification.find(params[:id])

    # Use atomic delete to avoid TOCTOU race condition
    deleted_count = Notification.where(id: notification.id, read: true).delete_all

    if deleted_count == 0
      # Notification was not deleted (it was unread)
      respond_to do |format|
        format.turbo_stream do
          # Re-render without changes - notification wasn't dismissed
          render turbo_stream: turbo_stream.replace(
            "notification_#{notification.id}",
            partial: "notification_row",
            locals: { notification: notification }
          )
        end
        format.html { redirect_to notifications_path, alert: "Cannot dismiss unread notification" }
      end
      return
    end

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.remove("notification_#{notification.id}"),
          turbo_stream.replace(
            "notification_badge",
            partial: "notification_badge",
            locals: { pending_count: Notification.pending_count }
          )
        ]
      end
      format.html { redirect_to notifications_path, notice: "Notification dismissed" }
    end
  end

  # DELETE /notifications/dismiss_all_read
  # Dismiss all read notifications
  def dismiss_all_read
    Notification.active.where(read: true).destroy_all

    redirect_to notifications_path, notice: "All read notifications dismissed"
  end
end
