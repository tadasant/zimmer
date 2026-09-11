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
# 180 is the default a server gets with nothing declared for it; the per-server
# field is the bottom half of this file.
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
# A catalog entry may name its own budget — `startup_timeout_sec` on the
# `mcp.json` entry ([#113](https://github.com/tadasant/zimmer/issues/113)) — and
# the 180 above is what a server gets when its entry names nothing. What a
# runtime does with a declared value is decided by the knob it has, and only one
# of the three can shorten a single server's budget without shortening something
# else:
#
#   Codex   writes the value into that server's `[mcp_servers.*]` table.
#           `startup_timeout_sec` is startup-scoped and per server, so a fast
#           server failing fast beside a slow one works here and only here.
#   Pi      writes it into that server's `.mcp.json` entry, but only when it is
#           LONGER than the default. `requestTimeoutMs` is the budget for every
#           request on the connection, tool calls included, so writing a short
#           one to make a startup fail fast would also kill that server's tool
#           calls at the same number. See
#           PiMcpConfigPostProcessor#apply_startup_timeouts!.
#   Claude  takes the LARGEST budget any of the session's servers asks for,
#           because `MCP_TIMEOUT` is one value for the whole process and nothing
#           per-server reaches it. Measured against CLI 2.1.268 rather than read
#           off a doc: a `.mcp.json` entry carrying Claude's own
#           `startupTimeoutSec` key (which its settings schema defines, 5-600s)
#           times out at `MCP_TIMEOUT` and not at the entry's value, and a
#           `mcpServers` table in project or user `settings.json` registers no
#           server at all.
#
# So a declared value shorter than the default reaches Codex alone, and a longer
# one reaches all three. Both directions are floored and capped (MIN_SECONDS,
# MAX_SECONDS), and an unusable value is ignored rather than coerced.
module McpStartupTimeout
  # The budget itself, in the coarser of the two units. Declared in seconds and
  # multiplied up rather than declared in milliseconds and divided down: integer
  # division would round a future value that is not a whole number of seconds
  # DOWN, handing the shorter budget to Codex — the runtime where running out
  # drops the server rather than merely delaying it. The one unit that cannot
  # lose precision is the one the number is written in.
  #
  # It is the DEFAULT: what a server gets when its catalog entry declares no
  # budget of its own.
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
  # rather than "your timeout is too short".
  #
  # The ceiling is set by what else measures the silence a starting server makes.
  # The startup dead zone — a runtime up, MCP servers connecting, nothing written
  # to the timeline yet — is as long as the longest budget any server on the
  # session gets, and two sweeps act on exactly that silence:
  # `RetryBudget::EMPTY_TURN_RESET_AFTER` (30 min) must outlast it or an
  # empty-turn restart becomes an unbounded loop, and
  # `CleanupOrphanedSessionsJob::INACTIVITY_THRESHOLD` (15 min) terminates and
  # restarts a `running` session whose timeline has been quiet that long. 600
  # seconds leaves the tighter of the two five minutes of margin, and
  # test/services/retry_budget_test.rb asserts both orderings so a change to any
  # of the three has to face the other two.
  MIN_SECONDS = 5
  MAX_SECONDS = 600

  class << self
    # What each of these servers declares, validated — `{ name => seconds }`,
    # carrying only the ones that declare something usable.
    #
    # A map rather than a lookup per name because both post-processors ask about
    # every entry in a config, on the prepare path: `ServersConfig.all` rebuilds
    # every Server object on each call and, when the catalog will not resolve,
    # re-runs the `air resolve` subprocess behind it. Once per config is once.
    #
    # A server the catalog does not know — an auto-injected Zimmer entry, a
    # repo's own checked-in config — is absent from the map and gets the default,
    # which is what it got before this field existed.
    #
    # @param server_names [Array<String>] catalog names
    # @return [Hash{String => Integer}] seconds, for the entries that declare one
    def declared_seconds_map(server_names)
      names = Array(server_names).compact
      return {} if names.empty?

      by_name = ServersConfig.all.index_by(&:name)
      names.each_with_object({}) do |name, map|
        declared = by_name[name]&.startup_timeout_seconds
        map[name] = declared if declared
      end
    end

    # The one budget that has to cover every server in a set — the largest any of
    # them asks for, never below the flat default.
    #
    # This exists for Claude, whose `MCP_TIMEOUT` is a property of the agent
    # process rather than of a server (see the module comment). Taking the max
    # means no server is ever given LESS room than its entry asks for; the cost is
    # that a fast server in a session with a slow one does not fail fast.
    #
    # @param server_names [Array<String>] catalog names of the session's servers
    # @return [Integer] seconds
    def ceiling_seconds(server_names)
      declared_seconds_map(server_names).values.push(SECONDS).max
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
