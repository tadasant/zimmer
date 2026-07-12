# frozen_string_literal: true

require "open3"
require "json"
require "shellwords"

# MCP Apps spike (SEP-1865 / io.modelcontextprotocol/ui).
#
# Zimmer orchestrates coding agents (Claude Code / Codex) *headlessly*, so those
# agents — which would normally be the MCP *host* that renders an MCP App UI
# fragment — have no screen to render on. This service demonstrates the creative
# "pipe it back" path: Zimmer's own web app acts as a second, independent MCP
# host. It connects to an app-capable MCP server, calls a tool, and reads the
# `ui://` HTML fragment + tool result that tool declares. The browser-side
# controller (`mcp_app_host_controller.js`) then renders that fragment in a
# sandboxed iframe on the session detail page and drives it over the MCP-Apps
# postMessage protocol.
#
# This is a proof-of-concept, gated behind ENV["ZIMMER_MCP_APPS_POC"]. It shells
# out to a dependency-free Node bridge (script/poc/mcp_apps/fetch_app_fragment.mjs)
# that speaks Streamable HTTP MCP.
class McpAppPreviewService
  BRIDGE = Rails.root.join("script/poc/mcp_apps/fetch_app_fragment.mjs").to_s
  DEFAULT_SERVER_URL = ENV.fetch("ZIMMER_MCP_APPS_POC_URL", "http://127.0.0.1:3001/mcp")
  DEFAULT_TOOL = ENV.fetch("ZIMMER_MCP_APPS_POC_TOOL", "generate_qr")
  TIMEOUT_SECONDS = 20

  Result = Struct.new(:ok, :data, :error, keyword_init: true) do
    def ok? = ok
  end

  def self.enabled?
    ENV["ZIMMER_MCP_APPS_POC"].present?
  end

  # Fetch an MCP App fragment + tool result for a tool call.
  # `tool_args` is a Hash serialized to the tool's inputSchema.
  def self.fetch(server_url: DEFAULT_SERVER_URL, tool: DEFAULT_TOOL, tool_args: {})
    new.fetch(server_url:, tool:, tool_args:)
  end

  def fetch(server_url:, tool:, tool_args:)
    cmd = [
      "node", BRIDGE,
      "--url", server_url,
      "--tool", tool,
      "--args", JSON.generate(tool_args)
    ]

    stdout, stderr, status = Open3.capture3(*cmd, stdin_data: "")

    unless status.success?
      return Result.new(ok: false, error: stderr.presence || "bridge exited #{status.exitstatus}")
    end

    data = JSON.parse(stdout)
    Result.new(ok: true, data: data)
  rescue JSON::ParserError => e
    Result.new(ok: false, error: "bad bridge output: #{e.message}")
  rescue => e
    Result.new(ok: false, error: "#{e.class}: #{e.message}")
  end
end
