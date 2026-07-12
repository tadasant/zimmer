# frozen_string_literal: true

# Zimmer's native MCP server: the tools (Mcp::Tools::*), their grouping
# (Mcp::Registry), and the per-connection scoping (Mcp::Context) behind
# POST /mcp. The protocol itself is the official MCP Ruby SDK's (the `mcp` gem,
# `MCP::` — note the casing); McpController wires the two together.
module Mcp
  # Server identity advertised in the MCP `initialize` handshake.
  SERVER_NAME = "zimmer"
  SERVER_TITLE = "Zimmer"

  # The app's release version, read from the repo's VERSION file at boot.
  SERVER_VERSION = begin
    File.read(Rails.root.join("VERSION")).strip
  rescue SystemCallError
    "0.0.0"
  end
end
