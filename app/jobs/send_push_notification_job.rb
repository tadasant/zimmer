# Job for sending push notifications about session status changes.
#
# Accepts a session_id and notification type, builds the appropriate payload,
# and sends to all active push subscriptions via WebPushService.
#
# Also creates a Notification record to track the notification in the app,
# allowing users to see a history of notifications and manage read/stale state.
#
# After creating the notification, broadcasts to the notification_badge Turbo Stream
# channel so the badge count updates in real-time on any page displaying it.
#
# Usage:
#   SendPushNotificationJob.perform_later(session.id, :session_complete)
#   SendPushNotificationJob.perform_later(session.id, :needs_input, nil, 3)
#   SendPushNotificationJob.perform_later(session.id, :custom_message, "Your custom message")
#
# Notification types:
#   :session_complete - Session finished successfully
#   :needs_input      - Session requires user input (debounced via transition_marker)
#   :session_failed   - Session encountered an error
#   :custom_message   - Custom message (body text passed as third argument)
#
# Debouncing:
#   needs_input notifications are typically scheduled with a wait (e.g., 60s).
#   The transition_marker is the value of session.custom_metadata["needs_input_count"]
#   captured at enqueue time. If the session has flapped (resume → pause) during
#   the wait, the counter will have advanced and the job no-ops. This prevents
#   spurious notifications for brief between-turn transitions.
class SendPushNotificationJob < ApplicationJob
  queue_as :default

  # Don't retry if session is not found
  discard_on ActiveRecord::RecordNotFound

  # Allow injection of services for testing
  attr_accessor :web_push_service, :inference_service, :broadcast_service

  # Supported notification types
  NOTIFICATION_TYPES = %w[session_complete needs_input session_failed custom_message elicitation_pending].freeze

  # Shorter timeout for notification summaries (user is waiting)
  SUMMARY_TIMEOUT = 15

  # Window used to detect a retried duplicate for notification types that don't
  # carry a transition_marker. Sized to comfortably exceed ApplicationJob's
  # `retry_on ActiveRecord::StatementTimeout, wait: :exponentially_longer,
  # attempts: 5` — total delay across 4 retries is ~362s (3s + 18s + 83s + 258s)
  # — plus job execution time, with headroom for slower retries.
  RECENT_NOTIFICATION_WINDOW = 15.minutes

  def initialize(*args)
    super
    @web_push_service ||= WebPushService.new
    @inference_service ||= HeadlessInferenceService.new
    @broadcast_service ||= BroadcastService.new
  end

  # @param session_id [Integer] The session to notify about
  # @param notification_type [String, Symbol] Type of notification to send
  # @param custom_message [String, nil] Custom message body (used with custom_message type)
  # @param transition_marker [Integer, nil] For needs_input: the
  #   needs_input_count value captured at enqueue time. The job no-ops if the
  #   session has transitioned out of needs_input or paused again since (the
  #   counter will no longer match), so brief flaps don't produce notifications.
  def perform(session_id, notification_type = "session_complete", custom_message = nil, transition_marker = nil)
    notification_type = notification_type.to_s

    unless NOTIFICATION_TYPES.include?(notification_type)
      Rails.logger.warn "[SendPushNotificationJob] Unknown notification type: #{notification_type}, defaulting to session_complete"
      notification_type = "session_complete"
    end

    session = Session.find(session_id)

    if notification_type == "needs_input" && stale_needs_input_transition?(session, transition_marker)
      Rails.logger.info "[SendPushNotificationJob] Skipping stale needs_input notification for session #{session_id} (status=#{session.status}, current_marker=#{session.custom_metadata&.dig('needs_input_count').inspect}, expected=#{transition_marker.inspect})"
      return
    end

    # Idempotency for retries (issue #3027): GoodJob retries can re-enter
    # `perform` with the same args after a partial failure. Without dedup, each
    # retry would insert another Notification row visible on /notifications.
    notification, created = find_or_create_notification(session, notification_type, transition_marker)
    unless created
      Rails.logger.info "[SendPushNotificationJob] Skipping duplicate send for session #{session_id} (type=#{notification_type}, marker=#{transition_marker.inspect}); existing notification id=#{notification.id}"
      return
    end

    Rails.logger.info "[SendPushNotificationJob] Created notification record #{notification.id} for session #{session_id}"

    # Broadcast badge update so any page showing the notification badge updates in real-time
    @broadcast_service.notification_badge(Notification.pending_count)

    payload = build_payload(session, notification_type, custom_message)

    result = @web_push_service.send_to_all(**payload)

    if result[:skipped]
      Rails.logger.info "[SendPushNotificationJob] Skipped push - VAPID keys not configured"
    else
      Rails.logger.info "[SendPushNotificationJob] Sent push notifications for session #{session_id}: #{result.inspect}"
    end
  end

  private

  # Determine whether a debounced needs_input job should bail out because the
  # session has transitioned out of needs_input or flapped through another
  # pause since the job was scheduled.
  #
  # If transition_marker is nil (legacy/un-debounced enqueue), we don't gate.
  def stale_needs_input_transition?(session, transition_marker)
    return false if transition_marker.nil?
    return true unless session.status == "needs_input"

    current_marker = session.custom_metadata&.dig("needs_input_count")
    current_marker != transition_marker
  end

  # Idempotently locate-or-create a Notification for this (session, type, marker).
  #
  # Returns [notification, created?]:
  # - For marker-bearing types (currently needs_input): uses find_or_create_by!
  #   against the partial unique index on
  #   (session_id, notification_type, transition_marker). Idempotent at the DB
  #   level even under concurrent retries — a RecordNotUnique race resolves to
  #   the existing row.
  # - For other types (no marker): the column is NULL so the partial index does
  #   not constrain it. Pre-flight a recent-window check so a job retry within
  #   RECENT_NOTIFICATION_WINDOW doesn't re-insert. Legitimate distinct events
  #   for the same type on the same session don't recur this quickly in practice.
  def find_or_create_notification(session, notification_type, transition_marker)
    if transition_marker
      find_or_create_marker_notification(session, notification_type, transition_marker)
    else
      find_or_create_unmarked_notification(session, notification_type)
    end
  end

  def find_or_create_marker_notification(session, notification_type, transition_marker)
    notification = session.notifications.find_or_create_by!(
      notification_type: notification_type,
      transition_marker: transition_marker
    )
    [ notification, notification.previously_new_record? ]
  rescue ActiveRecord::RecordNotUnique
    # Race: a concurrent job won the partial unique index. Resolve to the
    # existing row keyed by (session, type, marker) so the caller no-ops.
    notification = session.notifications.find_by!(
      notification_type: notification_type,
      transition_marker: transition_marker
    )
    [ notification, false ]
  end

  def find_or_create_unmarked_notification(session, notification_type)
    existing = session.notifications
      .where(notification_type: notification_type, transition_marker: nil)
      .where(created_at: RECENT_NOTIFICATION_WINDOW.ago..)
      .first
    if existing
      [ existing, false ]
    else
      [ session.notifications.create!(notification_type: notification_type), true ]
    end
  end

  # Build notification payload based on session and notification type
  #
  # @param session [Session] The session to build notification for
  # @param notification_type [String] The type of notification
  # @param custom_message [String, nil] Custom message body (used with custom_message type)
  # @return [Hash] Payload with :title, :body, :url, :data keys
  def build_payload(session, notification_type, custom_message = nil)
    title = build_title(session, notification_type)
    body = build_body(session, notification_type, custom_message)
    url = session_url(session)

    {
      title: title,
      body: body,
      url: url,
      data: {
        session_id: session.id,
        notification_type: notification_type
      }
    }
  end

  # Build notification title
  #
  # Uses the session title as the notification title for a personalized experience.
  #
  # @param session [Session] The session
  # @param notification_type [String] The notification type
  # @return [String] The notification title
  def build_title(session, notification_type)
    session.title.presence || "Session #{session.id}"
  end

  # Build notification body
  #
  # For needs_input notifications, generates an AI summary of the last assistant
  # message to provide context about what action is needed.
  # For custom_message notifications, uses the provided custom message.
  # For other notification types, falls back to simple descriptive messages.
  #
  # @param session [Session] The session
  # @param notification_type [String] The notification type
  # @param custom_message [String, nil] Custom message body (used with custom_message type)
  # @return [String] The notification body
  def build_body(session, notification_type, custom_message = nil)
    session_name = session.title.presence || "Session #{session.id}"

    case notification_type
    when "session_complete"
      "#{session_name} has finished"
    when "needs_input"
      # Generate AI summary of what the agent is waiting for
      generate_input_summary(session) || "Needs your input"
    when "session_failed"
      build_failure_body(session, session_name)
    when "elicitation_pending"
      custom_message.presence || "Action approval needed"
    when "custom_message"
      custom_message.presence || "#{session_name} needs attention"
    else
      "#{session_name} status updated"
    end
  end

  # Build the body for a session_failed notification.
  #
  # Surfaces the true failure reason — naming the failing MCP server(s) and their
  # error detail when available — so the push is actionable rather than a generic
  # "encountered an error". Falls back to the generic message only when no
  # failure_reason was recorded. Truncated to keep within push payload limits.
  #
  # @param session [Session] The failed session
  # @param session_name [String] Display name for the session
  # @return [String] The notification body
  def build_failure_body(session, session_name)
    summary = session.failure_summary
    return "#{session_name} encountered an error" if summary.blank?

    detail = session.failure_detail
    body = detail.present? ? "#{summary} — #{detail}" : summary
    body.truncate(200, omission: "...")
  end

  # Generate a summary of what input the agent is waiting for
  #
  # Uses HeadlessInferenceService to analyze the last assistant message and
  # produce a concise summary of the open question or likely next action needed.
  #
  # @param session [Session] The session to summarize
  # @return [String, nil] The generated summary, or nil if generation fails
  def generate_input_summary(session)
    last_assistant_message = extract_last_assistant_message(session)
    return nil if last_assistant_message.blank?

    prompt = build_summary_prompt(last_assistant_message)
    summary = @inference_service.generate(prompt, timeout: SUMMARY_TIMEOUT)

    # Keep it short for push notifications
    summary&.truncate(150, omission: "...")
  rescue StandardError => e
    Rails.logger.error "[SendPushNotificationJob] Failed to generate input summary: #{e.message}"
    nil
  end

  # Extract the last assistant message from the session transcript
  #
  # @param session [Session] The session
  # @return [String, nil] The last assistant message content
  def extract_last_assistant_message(session)
    conversation = session.formatted_conversation
    return nil if conversation.empty?

    # Find the last assistant message
    assistant_messages = conversation.select { |msg| msg[:role] == "assistant" }
    return nil if assistant_messages.empty?

    last_message = assistant_messages.last
    content = last_message[:content]

    # Truncate if too long
    content.truncate(2000, omission: "...")
  end

  # Build the prompt for generating the input summary
  #
  # @param last_message [String] The last assistant message
  # @return [String] The prompt for the inference backend
  def build_summary_prompt(last_message)
    <<~PROMPT
      Based on the following message from an AI coding assistant, generate a brief summary (under 100 characters) that describes what question or action is pending.

      Focus on:
      - What the assistant is asking or waiting for
      - What the likely next action is
      - Any blockers or issues mentioned

      Examples of good summaries:
      - "PR ready, needs approval to merge"
      - "Asking which test framework to use"
      - "Build failed, needs config fix"
      - "Waiting for API key to proceed"

      Message:
      #{last_message}

      Generate only the summary, nothing else. Do not use quotes or any formatting.
    PROMPT
  end

  # Build notification URL for the push notification click
  #
  # Directs users to the notifications page instead of directly to the session,
  # so they can see all pending notifications and mark them as read.
  #
  # @param _session [Session] The session (unused, kept for interface compatibility)
  # @return [String] The notifications page URL path
  def session_url(_session)
    "/notifications"
  end
end
