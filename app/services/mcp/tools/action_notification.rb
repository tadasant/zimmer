# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors the write side of Api::V1::NotificationsController: mark_read,
    # mark_all_read, dismiss and dismiss_all_read behind one action-dispatch tool.
    class ActionNotification < Tool
      ACTIONS = %w[mark_read mark_all_read dismiss dismiss_all_read].freeze

      tool_name "action_notification"

      description <<~DESC
        Manage notifications in the Zimmer.

        **Actions:**
        - **mark_read**: Mark a specific notification as read (requires "id")
        - **mark_all_read**: Mark all notifications as read
        - **dismiss**: Delete a notification (requires "id", must be read first)
        - **dismiss_all_read**: Delete all read notifications
      DESC

      input_schema({
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ACTIONS,
            description: "Action to perform."
          },
          id: {
            type: "number",
            description: "Notification ID. Required for mark_read and dismiss."
          }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, :action)

        case action
        when "mark_read" then mark_read(args["id"])
        when "mark_all_read" then mark_all_read
        when "dismiss" then dismiss(args["id"])
        when "dismiss_all_read" then dismiss_all_read
        else
          raise ToolError, "Unknown action \"#{action}\". Valid actions: #{ACTIONS.join(', ')}"
        end
      end

      private

      def mark_read(id)
        notification = find_notification(id, "mark_read")
        notification.mark_read!

        "## Notification Marked Read\n\n- **ID:** #{notification.id}\n- **Type:** #{notification.notification_type}"
      end

      def mark_all_read
        marked = Notification.active.unread.update_all(read: true)

        "## All Notifications Marked Read\n\n- **Marked:** #{marked}\n- **Remaining Pending:** #{Notification.pending_count}"
      end

      # Dismissing is destructive, so the REST API refuses to delete a notification
      # the user has not seen yet. Same guard here.
      def dismiss(id)
        notification = find_notification(id, "dismiss")
        raise ToolError, "Cannot dismiss unread notification" unless notification.read

        notification.destroy!

        "## Notification Dismissed\n\nNotification #{notification.id} has been deleted."
      end

      def dismiss_all_read
        dismissed = Notification.active.where(read: true).delete_all

        "## Read Notifications Dismissed\n\n- **Dismissed:** #{dismissed}\n- **Remaining Pending:** #{Notification.pending_count}"
      end

      def find_notification(id, action)
        raise ToolError, "\"id\" is required for the \"#{action}\" action." if id.blank?

        Notification.find_by(id: id) || raise(ToolError, "Notification not found: #{id}")
      end
    end
  end
end
