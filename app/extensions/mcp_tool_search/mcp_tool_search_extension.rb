# frozen_string_literal: true

# McpToolSearchExtension — run newly spawned Claude Code sessions with MCP tool
# search enabled (ENABLE_TOOL_SEARCH=true).
#
# Zimmer's baseline (in ClaudeSpawnEnv#build_claude_spawn_env) sets
# ENABLE_TOOL_SEARCH=false; this extension flips it on for enabled sessions by
# contributing the env var, which the spawn-env seam merges over the baseline.
# Removing this extension leaves the baseline standing — tool search stays off —
# so the feature is fully self-contained in app/extensions/mcp_tool_search/.
class McpToolSearchExtension < Ao::Extension
  def id
    "mcp_tool_search"
  end

  def title
    "MCP tool search"
  end

  def description
    "Spawn Claude Code sessions with ENABLE_TOOL_SEARCH=true so the agent can " \
      "search MCP tools on demand instead of loading every tool schema up front."
  end

  # Only meaningful for Claude Code sessions; other runtimes ignore the var.
  def spawn_env_contribution(context = {})
    return {} unless context[:runtime].to_s == "claude_code"

    { "ENABLE_TOOL_SEARCH" => "true" }
  end
end
