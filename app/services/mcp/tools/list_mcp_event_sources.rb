# frozen_string_literal: true

module Mcp
  module Tools
    # What the trigger form's MCP Event pickers offer: the catalog servers that publish events, and
    # each event type's argument and payload schemas.
    class ListMcpEventSources < Tool
      tool_name "list_mcp_event_sources"

      description <<~DESC
        List the catalog MCP servers that publish events through the MCP Events extension (draft
        SEP-3415), with each event type's `inputSchema` (the `arguments` an `mcp_event` trigger
        condition sends with every poll) and `payloadSchema` (the fields a prompt template can name
        as `{{event.<field>|untrusted}}` or `{{event.<field>|id}}`).

        Without `server`: the roster as of the last six-hourly sweep of every remote catalog server
        (`swept_at` says when; empty before the first sweep). With `server`: that one server, asked
        now — use it for a server the sweep has not reached yet, or to see a change at once.

        An `mcp_event` condition's configuration takes `server` (the catalog name) and `event_name`
        (exactly as listed here), plus optional `arguments` and `payload_filters`.
      DESC

      input_schema({
        type: "object",
        properties: {
          server: { type: "string", description: "A catalog MCP server name to ask now, instead of reading the swept roster." }
        },
        required: []
      })

      def call(args)
        McpEvents::Sources.listing(server: args["server"].to_s.strip.presence)
      rescue McpEvents::Sources::Unavailable => e
        raise ToolError, e.message
      end
    end
  end
end
