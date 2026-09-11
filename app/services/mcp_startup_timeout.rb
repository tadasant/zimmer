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
# 180 is the DEFAULT rather than the whole story — a catalog entry can name its
# own budget, which is the bottom half of this file.
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
# A single flat number for every server is the coarse answer, and
# [#113](https://github.com/tadasant/zimmer/issues/113) is where it stopped being
# the only one: a catalog entry may declare `startup_timeout_sec` and get its own
# budget, with the 180 above as the answer when it does not. What a runtime can
# do with that varies, and only two of the three can act on it per server:
#
#   Codex   writes the entry's own value into its `[mcp_servers.*]` table.
#   Pi      writes the entry's own value into its `.mcp.json` entry.
#   Claude  cannot. `MCP_TIMEOUT` is one value for the whole process and nothing
#           per-server reaches it — measured, not read off a doc: a `.mcp.json`
#           entry carrying Claude's own `startupTimeoutSec` key (which its
#           settings schema defines, 5-600s) times out at `MCP_TIMEOUT` and not
#           at the entry's value, and a `mcpServers` table in project or user
#           `settings.json` registers no server at all. So Zimmer hands Claude
#           the LARGEST budget any of the session's servers asks for: a slow
#           server still gets its room, and the fast ones get more than they
#           asked for rather than less. Fast-fail for one server among many is
#           not achievable on Claude today.
module McpStartupTimeout
  # The budget itself, in the coarser of the two units. Declared in seconds and
  # multiplied up rather than declared in milliseconds and divided down: integer
  # division would round a future value that is not a whole number of seconds
  # DOWN, handing the shorter budget to Codex — the runtime where running out
  # drops the server rather than merely delaying it. The one unit that cannot
  # lose precision is the one the number is written in.
  #
  # This is the DEFAULT now rather than the only value: it is what a server gets
  # when its catalog entry declares nothing, which is every server in the catalog
  # until one declares otherwise.
  SECONDS = 180

  # The same budget for the two runtimes that spell it in milliseconds: Claude's
  # `MCP_TIMEOUT` and Pi's `requestTimeoutMs`.
  MILLISECONDS = SECONDS * 1000

  # The field an `mcp.json` catalog entry declares its own budget in, in seconds.
  #
  # Seconds because that is the unit the number is decided in (see SECONDS), and
  # snake_case to sit beside `default_in_roots` and `unavailable` — the catalog's
  # other Zimmer-read fields. AIR's own server schema does not define it and does
  # not have to: it sets no `additionalProperties: false`, so `air validate`
  # passes an entry carrying this key and `air resolve` hands it back verbatim,
  # which is exactly how `unavailable` already reaches Zimmer. Neither AIR
  # adapter copies it into a runtime config either — both translate a fixed field
  # list — so the value reaches a runtime only where Zimmer itself writes it.
  CATALOG_KEY = "startup_timeout_sec"

  # Bounds on a declared value. Borrowed from Claude Code's own `startupTimeoutSec`
  # field (`z.coerce.number().int().min(5).max(600)` in 2.1.268), because a knob
  # that already exists somewhere is a better-argued range than one invented here.
  #
  # The floor matters more than it looks: a budget below a few seconds fails a
  # server that is merely starting, and the failure arrives as "server dropped"
  # rather than "your timeout is too short". The ceiling keeps one entry from
  # holding a session open indefinitely — and stays clear of
  # RetryBudget::EMPTY_TURN_RESET_AFTER (30 minutes), which has to outlast the
  # whole startup dead zone to keep an empty-turn restart bounded.
  MIN_SECONDS = 5
  MAX_SECONDS = 600

  class << self
    # The budget for one server, in seconds: what its catalog entry declares, or
    # the flat default when it declares nothing usable.
    #
    # @param server_name [String] the catalog entry's name
    # @return [Integer] seconds
    def seconds_for(server_name)
      declared_seconds(server_name) || SECONDS
    end

    # The same answer in milliseconds, for the runtimes that spell it that way.
    #
    # @return [Integer] milliseconds
    def milliseconds_for(server_name)
      seconds_for(server_name) * 1000
    end

    # What this server's catalog entry declares, validated — or nil when it
    # declares nothing, or declares something unusable.
    #
    # A server the catalog does not know (an auto-injected Zimmer entry, a repo's
    # own checked-in config) declares nothing and gets the default, which is what
    # it got before this field existed.
    #
    # @return [Integer, nil] seconds
    def declared_seconds(server_name)
      return nil if server_name.blank?

      ServersConfig.find(server_name)&.startup_timeout_seconds
    end

    # The one budget that has to cover every server in a set — the largest any of
    # them asks for, never below the flat default.
    #
    # This exists for Claude, whose `MCP_TIMEOUT` is a property of the agent
    # process rather than of a server (see the module comment). Taking the max
    # means no server is ever given LESS room than its entry asks for; the cost is
    # that a fast server in a session with a slow one does not fail fast.
    #
    # Indexes the catalog once rather than looking each name up separately: this
    # runs on the spawn path, for every server the session has.
    #
    # @param server_names [Array<String>] catalog names of the session's servers
    # @return [Integer] seconds
    def ceiling_seconds(server_names)
      by_name = ServersConfig.all.index_by(&:name)
      declared = Array(server_names).filter_map { |name| by_name[name]&.startup_timeout_seconds }

      declared.push(SECONDS).max
    end

    # @return [Integer] milliseconds
    def ceiling_milliseconds(server_names)
      ceiling_seconds(server_names) * 1000
    end

    # Validate a declared value. Returns the seconds, or nil when there is nothing
    # usable to honor.
    #
    # Integers only. A JSON string ("60") or a fraction (1.5) is a catalog typo
    # rather than an intent Zimmer can act on, and coercing one would honor a
    # number nobody wrote. Out of bounds is the same story, and both are logged:
    # the entry is written in another repository, so the only way its author hears
    # about a value that did nothing is Zimmer saying so.
    #
    # @param value [Object] the raw catalog value
    # @param server_name [String, nil] for the log line
    # @return [Integer, nil] seconds
    def normalize(value, server_name: nil)
      return nil if value.nil?

      unless value.is_a?(Integer)
        warn_ignored(server_name, value, "expected an integer number of seconds")
        return nil
      end

      unless value.between?(MIN_SECONDS, MAX_SECONDS)
        warn_ignored(server_name, value, "outside the #{MIN_SECONDS}-#{MAX_SECONDS}s range")
        return nil
      end

      value
    end

    private

    def warn_ignored(server_name, value, reason)
      Rails.logger.warn(
        "[McpStartupTimeout] Ignoring #{CATALOG_KEY}=#{value.inspect} on MCP server " \
        "#{server_name.inspect}: #{reason}. Falling back to #{SECONDS}s."
      )
    end
  end
end
