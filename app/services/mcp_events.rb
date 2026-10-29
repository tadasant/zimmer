# frozen_string_literal: true

# Zimmer as a CLIENT of the MCP Events extension: the draft SEP-3415, which lets a server publish
# typed events a client can poll, stream or receive by webhook.
#
# Zimmer speaks only the poll mode — `events/list` and `events/poll` — and only from Rails, never
# from an agent session: McpEventTriggerPollerJob polls a catalog server with the credentials a
# session would get for it and fires `mcp_event` trigger conditions. Push needs a long-lived
# listener Zimmer does not run, and webhook needs a public way into Zimmer, which it does not have
# (see limitations.md).
#
# The extension is an unmerged draft. SPEC_REVISION is the head commit this implementation was
# written against; docs/src/content/docs/sessions/mcp-events-spec-pin.md records what it covers and
# where it deliberately deviates. Bring both up to date whenever the SEP moves.
module McpEvents
  # The extension's identifier, under `capabilities.extensions` in what a server declares.
  EXTENSION_ID = "io.modelcontextprotocol/events"

  # The SEP-3415 head commit this implementation follows.
  SPEC_REVISION = "b08e4f9dd684f39d846d94089487fbeb28e666f5"

  # The extension's error codes, by name. The SEP calls the numbers provisional, so nothing else
  # names them.
  ERROR_CODES = {
    -32602 => :invalid_params,
    -32023 => :not_found,
    -32024 => :forbidden,
    -32025 => :resource_exhausted,
    -32026 => :unsupported
  }.freeze

  # The shape a server's event name may take before Zimmer stores it or sends it in a header:
  # printable ASCII with no spaces, which covers a gateway's `<slug>__<name>` prefixing.
  NAME_FORMAT = /\A[A-Za-z0-9._:\/-]{1,200}\z/

  # @param code [Integer, nil] a JSON-RPC error code
  # @return [Symbol, nil] the extension's name for it
  def self.error_name(code)
    ERROR_CODES[code]
  end
end
