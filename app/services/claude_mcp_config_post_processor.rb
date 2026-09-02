# frozen_string_literal: true

# Post-processes the `.mcp.json` file that AIR writes when preparing a Claude
# Code session. The JSON format hooks come from McpJsonConfigFormat (shared with
# Pi, which reads the same file); the shared injection/retarget orchestration
# lives in RuntimeConfigPostProcessor.
#
# Claude needs nothing beyond the format itself: the Claude AIR adapter already
# writes every configured server into `.mcp.json`, so this processor only has to
# adjust what is there.
class ClaudeMcpConfigPostProcessor < RuntimeConfigPostProcessor
  include McpJsonConfigFormat

  MCP_CONFIG_FILENAME = McpJsonConfigFormat::MCP_CONFIG_FILENAME
end
