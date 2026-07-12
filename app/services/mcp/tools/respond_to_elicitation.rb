# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors PATCH /api/v1/elicitations/:request_id/respond — the programmatic
    # counterpart to a human clicking accept/decline in the web UI. Resolution
    # and the session-blocking-state reconciliation live on the Elicitation
    # model, so this tool only validates, resolves, and clears the banner.
    class RespondToElicitation < Tool
      tool_name "respond_to_elicitation"

      description <<~DESC
        Respond to a pending Zimmer elicitation request — programmatically accept or decline it so the paused MCP flow that is waiting on it can continue.

        **Context:** When an MCP server needs human approval (e.g. a write-class action), it creates an *elicitation* and blocks, polling Zimmer until someone responds. Normally a human clicks "accept" / "decline" in the Zimmer web UI. This tool exposes that same resolution over the API, so an agent or automated test can unblock the flow without a human in the loop.

        **What it does:**
        - Looks up the elicitation by its public `request_id` (the `com.pulsemcp/request-id` identifier, not the DB primary key).
        - Records an `accept` (optionally with a structured `content` payload) or `decline`.
        - Returns the elicitation's resulting poll-response so you can confirm the outcome.

        **Example response:**
        ```
        ## Elicitation Accepted

        - **Request ID:** req-abc123
        - **Action:** accept
        - **Content:** { "approved": true }
        ```

        **Enum — action_type:**
        - **accept** — Approve the request; the waiting MCP flow proceeds. Pass optional `content` to supply the structured data the elicitation asked for.
        - **decline** — Reject the request; the waiting MCP flow unblocks with a declined outcome. `content` is ignored.

        **Use cases:**
        - Closed-loop testing of an MCP server's elicitation-gated behavior without a human clicking in the UI.
        - Automating approval of a known, expected elicitation as part of a larger orchestrated task.

        **Errors:**
        - Unknown `request_id` → 404 (elicitation not found).
        - Elicitation already resolved / not pending, or an invalid `action_type` → 422.
      DESC

      input_schema({
        type: "object",
        properties: {
          request_id: {
            type: "string",
            description: "The elicitation `request_id` — the public identifier the MCP server assigned when it created the elicitation (the `com.pulsemcp/request-id` value, surfaced in the poll URL). This is NOT the database primary key."
          },
          action_type: {
            type: "string",
            enum: [ "accept", "decline" ],
            description: 'How to resolve the elicitation. "accept" approves the request and lets the paused MCP flow continue (optionally with structured `content`); "decline" rejects it and unblocks the flow with a declined outcome.'
          },
          content: {
            type: "object",
            description: 'Optional structured JSON object supplied with an "accept" response (e.g. the form fields the elicitation requested). Ignored for "decline". Must be a JSON object, not a scalar or array.'
          }
        },
        required: [ "request_id", "action_type" ]
      })

      def call(args)
        request_id = require_arg(args, :request_id).to_s
        action_type = require_arg(args, :action_type).to_s

        elicitation = Elicitation.find_by(request_id: request_id)
        raise ToolError, "Elicitation not found for request_id: #{request_id}" unless elicitation

        unless elicitation.pending?
          raise ToolError, "Elicitation has already been resolved (status: #{elicitation.status})"
        end

        unless Elicitation::RESOLVE_ACTIONS.include?(action_type)
          raise ToolError, "action_type must be one of: #{Elicitation::RESOLVE_ACTIONS.join(', ')}"
        end

        elicitation.resolve!(action: action_type, content: response_content(args["content"]))
        remove_banner(elicitation)

        poll_response = elicitation.to_poll_response
        lines = [
          "## Elicitation #{action_type == 'accept' ? 'Accepted' : 'Declined'}",
          "",
          "- **Request ID:** #{request_id}",
          "- **Action:** #{poll_response[:action]}"
        ]
        lines << "- **Content:** #{poll_response[:content].to_json}" unless poll_response[:content].nil?
        lines.join("\n")
      end

      private

      # The wire form is a JSON object; a scalar or array would be stored as-is and
      # then confuse the MCP server polling for its form fields, so reject it here.
      def response_content(content)
        return nil if content.blank?
        raise ToolError, "content must be a JSON object" unless content.is_a?(Hash)
        content
      end

      # Guarded so a broadcast failure never fails the tool call — the resolution
      # has already been persisted.
      def remove_banner(elicitation)
        BroadcastService.new.remove_elicitation_banner(elicitation.session, elicitation)
      rescue => e
        Rails.logger.error "[Mcp::Tools::RespondToElicitation] Failed to broadcast elicitation removal: #{e.message}"
      end
    end
  end
end
