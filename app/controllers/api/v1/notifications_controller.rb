# frozen_string_literal: true

# API controller for managing notifications and sending push notifications.
#
# Notifications are created when sessions need user attention (e.g., needs_input).
# They track read/stale status for the notification inbox.
# Also provides an endpoint to trigger push notifications programmatically.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::NotificationsController < Api::BaseController
  before_action :set_notification, only: [ :show, :mark_read, :dismiss ]

  # GET /api/v1/notifications
  # List active (non-stale) notifications.
  #
  # Query parameters:
  #   - status: Filter by read status ("read", "unread")
  #   - page: Page number (default: 1)
  #   - per_page: Results per page (default: 25, max: 100)
  def index
    scope = Notification.active
                        .includes(:session)
                        .order(created_at: :desc)

    scope = scope.where(read: true) if params[:status] == "read"
    scope = scope.unread if params[:status] == "unread"

    result = paginate(scope)

    render json: {
      notifications: result[:records].map { |n| notification_json(n) },
      pagination: result[:pagination]
    }
  end

  # GET /api/v1/notifications/:id
  # Get a single notification.
  def show
    render json: { notification: notification_json(@notification) }
  end

  # GET /api/v1/notifications/badge
  # Get the unread notification count.
  def badge
    render json: { pending_count: Notification.pending_count }
  end

  # PATCH /api/v1/notifications/:id/mark_read
  # Mark a single notification as read.
  def mark_read
    @notification.mark_read!
    render json: { notification: notification_json(@notification) }
  end

  # PATCH /api/v1/notifications/mark_all_read
  # Mark all active notifications as read.
  def mark_all_read
    count = Notification.active.unread.update_all(read: true)
    render json: { marked_count: count, pending_count: Notification.pending_count }
  end

  # DELETE /api/v1/notifications/:id
  # Dismiss (delete) a single notification. Only allowed if already read.
  def dismiss
    deleted_count = Notification.where(id: @notification.id, read: true).delete_all

    if deleted_count == 0
      render json: { error: "Cannot dismiss", message: "Cannot dismiss unread notification" }, status: :unprocessable_entity
    else
      head :no_content
    end
  end

  # DELETE /api/v1/notifications/dismiss_all_read
  # Dismiss all read notifications.
  def dismiss_all_read
    count = Notification.active.where(read: true).delete_all
    render json: { dismissed_count: count, pending_count: Notification.pending_count }
  end

  # POST /api/v1/notifications/push
  # Send a push notification about a session.
  #
  # Request body:
  #   - session_id: ID of the session to notify about (required)
  #   - message: Custom notification body text (required)
  #
  # The notification title is derived from the session's title.
  # A Notification record is created for in-app tracking.
  def push
    unless params[:session_id].present?
      render json: { error: "Missing parameter", message: "session_id is required" }, status: :unprocessable_entity
      return
    end

    unless params[:message].present?
      render json: { error: "Missing parameter", message: "message is required" }, status: :unprocessable_entity
      return
    end

    session = Session.find(params[:session_id])

    SendPushNotificationJob.perform_later(session.id, :custom_message, params[:message])

    render json: {
      success: true,
      message: "Push notification queued",
      session_id: session.id
    }
  end

  private

  def set_notification
    @notification = Notification.find(params[:id])
  end

  def notification_json(notification)
    json = {
      id: notification.id,
      session_id: notification.session_id,
      notification_type: notification.notification_type,
      read: notification.read,
      stale: notification.stale,
      created_at: notification.created_at.iso8601,
      updated_at: notification.updated_at.iso8601
    }

    if notification.session
      json[:session] = {
        id: notification.session.id,
        slug: notification.session.slug,
        title: notification.session.title,
        status: notification.session.status
      }
    end

    json
  end
end
