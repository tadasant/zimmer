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
#   Pi            requestTimeoutMs = 180000     per `.mcp.json` entry, milliseconds
#                 (PiMcpConfigPostProcessor#apply_startup_timeouts!)
#
# Each runtime's own default was measured against the pinned binary rather than
# read off a doc. Codex's is 30 seconds (`@openai/codex@0.146.0`), which leaves
# under twice the observed cold-start worst case. Pi's is the MCP SDK's 60
# seconds, reached through the `pi-mcp-adapter` extension that supplies Pi's
# whole MCP client — better, and still only about 3x an 18-second worst case
# measured on an idle box. Three minutes is what Claude gets, and one budget for
# all three keeps a runtime's default from deciding whether a session's MCP
# servers connect.
#
# Pi's spelling covers more than a startup: `requestTimeoutMs` is the budget for
# every request on the connection, tool calls included. There is no
# connect-only key to write instead — see
# PiMcpConfigPostProcessor#apply_startup_timeouts!.
#
# The cost of the wider budget is the same one Claude pays: a server that hangs
# holds the handshake for three minutes rather than thirty seconds. That is the
# deliberate trade — a slow start is recoverable, a dropped server is not.
#
# A single flat number for every server is the coarse answer; per-server
# configurability is [#113](https://github.com/tadasant/zimmer/issues/113).
module McpStartupTimeout
  # The budget itself, in the coarser of the two units. Declared in seconds and
  # multiplied up rather than declared in milliseconds and divided down: integer
  # division would round a future value that is not a whole number of seconds
  # DOWN, handing the shorter budget to Codex — the runtime where running out
  # drops the server rather than merely delaying it. The one unit that cannot
  # lose precision is the one the number is written in.
  SECONDS = 180

  # The same budget for Claude's `MCP_TIMEOUT`, which is milliseconds.
  MILLISECONDS = SECONDS * 1000
end
