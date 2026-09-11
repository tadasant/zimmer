# frozen_string_literal: true

# MCP Apps (SEP-1865, `io.modelcontextprotocol/ui`) — Zimmer as a second MCP host.
#
# Zimmer drives its coding agents *headlessly*, so the agent that calls a
# `ui://`-bearing MCP tool is not a host that can render anything. Zimmer's web
# app is. When the agent calls such a tool, the session detail page fetches the
# tool's `ui://` fragment from the same MCP server the agent was talking to,
# renders it in a sandboxed iframe, and brokers the MCP-Apps postMessage protocol
# between that fragment and the server (and, for `ui/message`, the agent).
#
# Three properties hold the whole design together, and every file under this
# namespace exists to keep one of them true:
#
#   1. **The agent's call is never re-executed.** The fragment is fed by the
#      `ToolResult` already in the transcript. The only request Zimmer makes on
#      the way to a first render is the read-only `resources/read` for the
#      fragment itself.
#   2. **The fragment is untrusted.** It is served from its own endpoint into an
#      iframe with no `allow-same-origin`, under a response-header CSP derived
#      from the resource's own `_meta.ui.csp` — and a `default-src 'none'` one
#      when the resource declares nothing. See ContentSecurityPolicy.
#   3. **The fragment talks to its own server and nothing else.** Its
#      `tools/call` and `resources/read` are proxied server-side by Rails, over
#      the session's own MCP configuration and credentials, and only for tools
#      that server has marked app-callable. The browser never holds a credential
#      and never reaches the MCP server directly. See Proxy.
#
# Off by default, and per-server opt-in on top of that — see Policy.
module McpApps
  # There is no protocol-version constant here on purpose. `ui/initialize` is
  # answered in the browser, by mcp_app_host_controller.js, which negotiates
  # against its own list — a second copy on this side would be a fact nothing
  # reads and nothing keeps true.

  # Where the extension hangs its metadata on a tool, a resource, or a tool
  # result. The spec's own key is the reverse-DNS one; `ui` is the shorthand the
  # reference SDKs (and FastMCP's `meta={"ui": ...}`) write, and servers in the
  # wild emit either. Read in this order, first hit wins.
  META_KEYS = [ "io.modelcontextprotocol/ui", "ui" ].freeze

  # The URI scheme an MCP App fragment is addressed by.
  UI_SCHEME = "ui://"

  # The extension's `_meta` block on an MCP object, whichever spelling it used.
  #
  # @param object [Hash, nil] a tool, resource, or result from an MCP response
  # @return [Hash] the ui metadata, or an empty hash
  def self.ui_meta(object)
    meta = object.is_a?(Hash) ? object["_meta"] : nil
    return {} unless meta.is_a?(Hash)

    META_KEYS.each do |key|
      value = meta[key]
      return value if value.is_a?(Hash)
    end

    {}
  end

  # The `ui://` resource a tool declares as its view, if it declares one.
  #
  # @param tool [Hash, nil] one entry from a `tools/list` result
  # @return [String, nil]
  def self.resource_uri_for(tool)
    uri = ui_meta(tool)["resourceUri"]
    return nil unless uri.is_a?(String) && uri.start_with?(UI_SCHEME)

    uri
  end

  # Whether a tool is one the server has marked callable BY THE VIEW rather than
  # by the model — `visibility: ["app"]`. This is the allowlist the server-side
  # proxy enforces; see Proxy for why an app declaring nothing gets nothing.
  #
  # @param tool [Hash, nil] one entry from a `tools/list` result
  # @return [Boolean]
  def self.app_callable?(tool)
    visibility = ui_meta(tool)["visibility"]
    visibility.is_a?(Array) && visibility.include?("app")
  end
end
