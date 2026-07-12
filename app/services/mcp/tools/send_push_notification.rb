# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors POST /api/v1/notifications/push — enqueues SendPushNotificationJob
    # for a session with a custom message.
    class SendPushNotification < Tool
      tool_name "send_push_notification"

      description <<~DESC
        Send a push notification to the user about a session that needs attention.

        **Use this tool when:**
        - A session genuinely requires human intervention (e.g., missing credentials, approval needed)
        - You want to alert the user about an important session status change

        **Parameters:**
        - **session_id**: The numeric ID or slug of the session the notification relates to
        - **message**: A clear, actionable message describing what the user needs to do

        **Note:** Use this sparingly - only for situations that truly require human attention.
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: "Session ID (numeric) or slug (string) to send the push notification for."
          },
          message: {
            type: "string",
            description: 'The notification message to send. Should describe why human attention is needed (e.g., "Needs API key for Proctor MCP server to proceed").'
          }
        },
        required: [ "session_id", "message" ]
      })

      def call(args)
        session = find_session(args["session_id"])
        message = require_arg(args, :message)

        SendPushNotificationJob.perform_later(session.id, :custom_message, message)

        <<~TEXT.strip
          ## Push Notification Sent

          - **Session ID:** #{session.id}
          - **Notification:** #{message}
          - **Status:** Push notification queued
        TEXT
      end
    end
  end
end
