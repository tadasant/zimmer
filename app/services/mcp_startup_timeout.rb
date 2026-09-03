# frozen_string_literal: true

# How long a runtime waits for an MCP server to start and answer `initialize`,
# stated once for every runtime that has a knob for it.
#
# The number exists because of what a cold clone costs. Every npx MCP server is
# pointed at `<clone>/.npm-cache` (NpxCacheIsolator), and `NPM_CONFIG_CACHE`
# moves the *whole* npm cache — `_cacache` and the tarball store included — so
# the packages `bin/preinstall-mcp-packages` warms into the image's `~/.npm` at
# build time reach no MCP server. The first launch in a fresh clone downloads
# every one of them from the registry, concurrently, while the runtime is
# holding the handshake open.
#
# Measured on the production droplet, cold, all nine npx servers in `mcp.json`
# installing at once into one clone cache: 18s for the slowest, 487MB fetched.
# That is on an idle box with a fast link; a box launching several sessions at
# once has less of both.
#
# Each runtime spells it differently and Zimmer sets it in the runtime's own
# idiom, but the budget is one decision:
#
#   Claude Code   MCP_TIMEOUT=180000            env var, milliseconds, all servers
#                 (ClaudeSpawnEnv#configure_mcp_env)
#   Codex         startup_timeout_sec = 180     per `[mcp_servers.*]` table, seconds
#                 (CodexConfigTomlPostProcessor#apply_startup_timeouts!)
#
# Codex's own default is 30 seconds — measured against the pinned
# `@openai/codex@0.146.0` binary, not read off a doc — which leaves under twice
# the observed cold-start worst case. Three minutes is the headroom Claude has
# always had, and giving Codex the same one keeps a runtime choice from deciding
# whether a session's MCP servers connect.
#
# A single flat number for every server is the coarse answer; per-server
# configurability is [#113](https://github.com/tadasant/zimmer/issues/113).
module McpStartupTimeout
  # The budget itself. Milliseconds, because Claude's variable is in
  # milliseconds and an integer number of them is the exact value; #seconds
  # divides down for runtimes that want seconds.
  MILLISECONDS = 180_000

  module_function

  # The same budget in whole seconds, for a runtime whose knob is `_sec`.
  def seconds
    MILLISECONDS / 1000
  end
end
