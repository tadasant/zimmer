# frozen_string_literal: true

module McpApps
  # Splits the `mcp__<server>__<tool>` tool name both runtimes write into the
  # transcript back into its two halves.
  #
  # The split cannot be done on the delimiter alone. `__` is legal inside a tool
  # name (`mcp__remote-fs__remote-filesystem__upload_file` is a real one), and
  # Codex sanitizes the server half — every character outside `[A-Za-z0-9_-]`
  # becomes `_` — so the name in the transcript is not always the name in the
  # catalog. Both are resolved the only way that is unambiguous: against the list
  # of servers the session actually has, longest match first.
  module ToolName
    PREFIX = "mcp__"
    DELIMITER = "__"

    Parsed = Data.define(:server, :tool)

    # @param tool_name [String, nil] as it appears in the transcript
    # @param servers [Array<String>] catalog names of the session's MCP servers
    # @return [Parsed, nil] nil when this is not an MCP tool call on one of them
    def self.parse(tool_name, servers:)
      name = tool_name.to_s
      return nil unless name.start_with?(PREFIX)

      rest = name.delete_prefix(PREFIX)

      # Longest first: a deployment with both `zimmer` and `zimmer-sessions`
      # attached must not read `mcp__zimmer-sessions__x` as server `zimmer`.
      servers.sort_by { |server| -server.length }.each do |server|
        [ server, sanitize(server) ].uniq.each do |candidate|
          prefix = "#{candidate}#{DELIMITER}"
          next unless rest.start_with?(prefix)

          tool = rest.delete_prefix(prefix)
          return Parsed.new(server: server, tool: tool) if tool.present?
        end
      end

      nil
    end

    # Codex's `MCP_TOOL_NAME_DELIMITER` sanitization, matching
    # CodexMcpStatusDetector#sanitize.
    def self.sanitize(name)
      name.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
    end
  end
end
