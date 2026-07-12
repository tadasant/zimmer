# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors the read side of Api::V1::NotificationsController — GET
    # /api/v1/notifications (list), /:id (show) and /badge (unread count) — behind
    # one tool with three modes.
    class GetNotifications < Tool
      DEFAULT_PER_PAGE = 25
      MAX_PER_PAGE = 100

      tool_name "get_notifications"

      description <<~DESC
        Get notifications from the Zimmer.

        **Modes:**
        - **Badge only**: Set badge_only=true to get just the pending notification count
        - **Get by ID**: Provide an id to get a specific notification
        - **List**: List notifications with optional status filter and pagination

        **Use cases:**
        - Check how many unread notifications you have
        - Review notification details
        - Monitor session alerts
      DESC

      input_schema({
        type: "object",
        properties: {
          id: { type: "number", description: "Get a specific notification by ID." },
          badge_only: {
            type: "boolean",
            description: "If true, returns only the pending notification count. Default: false"
          },
          status: {
            type: "string",
            enum: [ "read", "unread" ],
            description: "Filter by status when listing."
          },
          page: { type: "number", minimum: 1, description: "Page number. Default: 1" },
          per_page: {
            type: "number",
            minimum: 1,
            maximum: 100,
            description: "Results per page. Default: 25"
          }
        },
        required: []
      })

      def call(args)
        return badge if args["badge_only"]
        return show(args["id"]) if args["id"].present?
        list(args)
      end

      private

      def badge
        "## Notification Badge\n\n**Pending notifications:** #{Notification.pending_count}"
      end

      def show(id)
        notification = Notification.find_by(id: id)
        raise ToolError, "Notification not found: #{id}" unless notification

        lines = [
          "## Notification ##{notification.id}",
          "",
          "- **Type:** #{notification.notification_type}",
          "- **Read:** #{notification.read ? 'Yes' : 'No'}",
          "- **Session ID:** #{notification.session_id}"
        ]

        if notification.session
          lines << "- **Session Title:** #{notification.session.title}"
          lines << "- **Session Status:** #{notification.session.status}"
        end

        lines << "- **Created:** #{notification.created_at.iso8601}"
        lines.join("\n")
      end

      def list(args)
        scope = Notification.active.includes(:session).order(created_at: :desc)
        scope = scope.where(read: true) if args["status"] == "read"
        scope = scope.unread if args["status"] == "unread"

        page = [ args["page"].to_i.nonzero? || 1, 1 ].max
        per_page = [ [ args["per_page"].to_i.nonzero? || DEFAULT_PER_PAGE, 1 ].max, MAX_PER_PAGE ].min

        total_count = scope.count
        total_pages = (total_count.to_f / per_page).ceil
        notifications = scope.limit(per_page).offset((page - 1) * per_page)

        return "## Notifications\n\nNo notifications found." if notifications.empty?

        lines = [ "## Notifications (#{total_count} total, page #{page} of #{total_pages})", "" ]
        notifications.each do |notification|
          read_status = notification.read ? "read" : "unread"
          session = notification.session
          session_info = session ? " - #{session.title} (#{session.status})" : ""
          lines << "- **##{notification.id}** [#{read_status}] #{notification.notification_type}#{session_info} (#{notification.created_at.iso8601})"
        end

        lines.join("\n")
      end
    end
  end
end
