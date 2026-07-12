# frozen_string_literal: true

module Mcp
  # Raised by a tool when the call cannot be completed for a reason the calling
  # agent can act on (bad arguments, missing record, forbidden by scoping).
  # Mcp::Server turns this into a tool result with `isError: true` and the message
  # as text, which is what MCP clients surface to the model — as opposed to a
  # JSON-RPC protocol error, which the model never sees.
  class ToolError < StandardError; end
end
