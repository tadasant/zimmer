# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors the /api/v1/sessions/:session_id/enqueued_messages surface
    # (index/show/create/update/destroy/reorder/interrupt) plus the
    # force_immediate branch of SessionsController#follow_up, which is what the
    # "send_now" action is: stage a message and hand it to
    # Sessions::InterruptService in one step.
    #
    # Both interrupt paths go through Sessions::InterruptService so the
    # per-session advisory lock and exactly-once FIFO delivery contract hold for
    # MCP callers exactly as they do for the REST and web surfaces.
    class ManageEnqueuedMessages < Tool
      ACTIONS = %w[list get create update delete reorder interrupt send_now].freeze

      # The queue preview in list/create/update output is capped, matching the
      # decoupled server's 200-char snippet.
      CONTENT_PREVIEW_LIMIT = 200

      tool_name "manage_enqueued_messages"

      description <<~DESC
        Queue messages for later delivery or send messages immediately to an agent session.

        **Quick guide — two ways to send a message:**
        - **send_now**: Interrupt the session and deliver a message immediately, even if the session is running. One step — just provide "content".
        - **create**: Add a message to the queue for delivery when the session finishes its current work. Does NOT send immediately.

        Use "send_now" when you need the agent to act on something urgently. Use "create" when the message can wait until the session is idle.

        **All actions:**
        - **send_now**: Interrupt the session and deliver a message immediately (requires "content"). The session is paused, the message is sent, and the session resumes with this message. Works regardless of session state.
        - **create**: Add a new message to the end of the queue for later delivery (requires "content"). The message waits until the session becomes idle.
        - **list**: List all enqueued messages for a session (supports pagination with "page" and "per_page")
        - **get**: Get a specific enqueued message by ID (requires "message_id")
        - **update**: Update an existing queued message's content or goal (requires "message_id")
        - **delete**: Remove a message from the queue (requires "message_id")
        - **reorder**: Change a message's position in the queue (requires "message_id" and "position")
        - **interrupt**: Pause the session and send an existing queued message immediately (requires "message_id"). Prefer "send_now" for new messages — "interrupt" is for promoting an already-queued message.
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: "Session ID (numeric) or slug (string)."
          },
          action: {
            type: "string",
            enum: ACTIONS,
            description: 'Action to perform. Use "send_now" to interrupt and deliver immediately. Use "create" to queue for later.'
          },
          message_id: {
            type: "number",
            description: "Message ID. Required for get, update, delete, reorder, and interrupt."
          },
          content: {
            type: "string",
            description: "Message content. Required for create and send_now. Optional for update."
          },
          goal: {
            type: "string",
            description: "Goal for this message. Optional for create, send_now, and update."
          },
          position: {
            type: "number",
            minimum: 1,
            description: "New position in queue. Required for reorder."
          },
          page: { type: "number", minimum: 1, description: "Page number for list. Default: 1" },
          per_page: {
            type: "number",
            minimum: 1,
            maximum: 100,
            description: "Results per page for list. Default: 25"
          }
        },
        required: [ "session_id", "action" ]
      })

      def call(args)
        session = find_session(args["session_id"])
        action = require_arg(args, :action).to_s

        case action
        when "list" then list(session, args)
        when "get" then show(session, args)
        when "create" then create(session, args)
        when "update" then update(session, args)
        when "delete" then destroy(session, args)
        when "reorder" then reorder(session, args)
        when "interrupt" then interrupt(session, args)
        when "send_now" then send_now(session, args)
        else
          raise ToolError, "Unknown action \"#{action}\". Valid actions: #{ACTIONS.join(', ')}"
        end
      end

      private

      def list(session, args)
        page = [ args["page"].to_i.nonzero? || 1, 1 ].max
        per_page = [ [ args["per_page"].to_i.nonzero? || 25, 1 ].max, 100 ].min

        scope = session.enqueued_messages.ordered
        total_count = scope.count
        total_pages = (total_count.to_f / per_page).ceil
        messages = scope.limit(per_page).offset((page - 1) * per_page)

        return "## Enqueued Messages\n\nNo enqueued messages found." if messages.empty?

        lines = [ "## Enqueued Messages (#{total_count} total, page #{page} of #{total_pages})", "" ]
        messages.each do |message|
          lines << "### Position #{message.position} (ID: #{message.id})"
          lines << "- **Status:** #{message.status}"
          lines << "- **Content:** #{preview(message.content)}"
          lines << "- **Goal:** #{message.goal}" if message.goal.present?
          lines << ""
        end
        lines.join("\n")
      end

      def show(session, args)
        message = find_message(session, args)

        lines = [
          "## Enqueued Message ##{message.id}",
          "",
          "- **Session ID:** #{message.session_id}",
          "- **Position:** #{message.position}",
          "- **Status:** #{message.status}",
          "- **Content:** #{message.content}"
        ]
        lines << "- **Goal:** #{message.goal}" if message.goal.present?
        lines << "- **Created:** #{message.created_at.iso8601}"
        lines.join("\n")
      end

      def create(session, args)
        content = args["content"].to_s.strip
        raise ToolError, '"content" is required for the "create" action.' if content.blank?

        max_position = session.enqueued_messages.maximum(:position) || 0
        message = session.enqueued_messages.new(
          content: content,
          goal: args["goal"].to_s.strip.presence,
          position: max_position + 1,
          status: "pending"
        )

        raise ToolError, "Validation failed: #{message.errors.full_messages.join(', ')}" unless message.save

        session.logs.create!(content: "Enqueued message added at position #{message.position}", level: "info")

        [
          "## Message Queued",
          "",
          "Message added to queue — it will be delivered when the session becomes idle.",
          "",
          "- **ID:** #{message.id}",
          "- **Position:** #{message.position}",
          "- **Status:** #{message.status}",
          "- **Content:** #{preview(message.content)}"
        ].join("\n")
      end

      def update(session, args)
        message = find_message(session, args)

        attrs = {}
        attrs[:content] = args["content"].to_s.strip if args.key?("content")
        attrs[:goal] = args["goal"].to_s.strip.presence if args.key?("goal")

        raise ToolError, "Validation failed: Content can't be blank" if attrs.key?(:content) && attrs[:content].blank?

        raise ToolError, "Validation failed: #{message.errors.full_messages.join(', ')}" unless message.update(attrs)

        session.logs.create!(content: "Enqueued message at position #{message.position} updated", level: "info")

        [
          "## Message Updated",
          "",
          "- **ID:** #{message.id}",
          "- **Position:** #{message.position}",
          "- **Content:** #{preview(message.content)}"
        ].join("\n")
      end

      def destroy(session, args)
        message = find_message(session, args)
        position = message.position

        ActiveRecord::Base.transaction do
          message.destroy!
          session.enqueued_messages
                 .where("position > ?", position)
                 .update_all("position = position - 1")
          session.logs.create!(content: "Enqueued message at position #{position} removed", level: "info")
        end

        "## Message Deleted\n\nEnqueued message #{message.id} has been removed from the queue."
      end

      def reorder(session, args)
        message = find_message(session, args)
        new_position = args["position"].to_i
        raise ToolError, '"position" is required for the "reorder" action.' if args["position"].nil?
        raise ToolError, "Invalid position: Position must be >= 1" if new_position < 1

        old_position = message.position
        message.reorder_to(new_position)
        session.logs.create!(content: "Enqueued message moved from position #{old_position} to #{new_position}", level: "info")

        [
          "## Message Reordered",
          "",
          "- **ID:** #{message.id}",
          "- **New Position:** #{message.reload.position}"
        ].join("\n")
      end

      def interrupt(session, args)
        message = find_message(session, args)

        result = Sessions::InterruptService.new(
          session: session,
          enqueued_message: message,
          actor: "mcp"
        ).call

        raise ToolError, "Cannot interrupt: #{result.error}" unless result.success?

        session.reload
        [
          "## Message Sent as Interrupt",
          "",
          "- **Session ID:** #{session.id}",
          "- **Session Status:** #{session.status}",
          "- **Message:** Message sent as interrupt"
        ].join("\n")
      end

      # The one-step form of interrupt: stage the message, then deliver it through
      # the same InterruptService. Mirrors SessionsController#follow_up with
      # force_immediate, including its all-or-nothing cleanup — a message that
      # could not be dispatched is removed rather than left to surface later as a
      # surprise queued follow-up.
      def send_now(session, args)
        content = args["content"].to_s.strip
        raise ToolError, '"content" is required for the "send_now" action.' if content.blank?

        if content.length > Session::PROMPT_MAX_LENGTH
          raise ToolError, "Validation failed: content is too long (maximum #{Session::PROMPT_MAX_LENGTH} characters)"
        end

        unless session.running? || session.waiting? || session.needs_input?
          raise ToolError, "Cannot send follow-up: Session is #{session.status}. " \
                           "Follow-up prompts can only be sent to running, waiting, or needs_input sessions."
        end

        max_position = session.enqueued_messages.maximum(:position) || 0
        message = session.enqueued_messages.create!(
          content: content,
          goal: args["goal"].to_s.strip.presence,
          position: max_position + 1,
          status: "pending"
        )

        result = Sessions::InterruptService.new(
          session: session,
          enqueued_message: message,
          actor: "mcp_send_now"
        ).call

        unless result.success?
          discard_staged_message(message)
          raise ToolError, "Cannot send follow-up: #{result.error}"
        end

        session.reload
        [
          "## Message Sent Immediately",
          "",
          "The session was interrupted and the message was delivered.",
          "",
          "- **Session ID:** #{session.id}",
          "- **Session Status:** #{session.status}",
          "- **Result:** Follow-up prompt sent immediately"
        ].join("\n")
      end

      # A concurrent interrupt may have already claimed/destroyed the row — that
      # is fine, there is nothing left to clean up.
      def discard_staged_message(message)
        message.reload
        message.destroy! if message.status == "pending"
      rescue ActiveRecord::RecordNotFound
        nil
      end

      def find_message(session, args)
        message_id = args["message_id"]
        if message_id.nil?
          raise ToolError, "\"message_id\" is required for the \"#{args['action']}\" action."
        end

        message = session.enqueued_messages.find_by(id: message_id.to_i)
        raise ToolError, "Enqueued message not found: #{message_id}" unless message
        message
      end

      def preview(content)
        content.length > CONTENT_PREVIEW_LIMIT ? "#{content[0, CONTENT_PREVIEW_LIMIT]}..." : content
      end
    end
  end
end
