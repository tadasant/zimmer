# frozen_string_literal: true

# Writes and post-processes the `.mcp.json` the Pi MCP adapter reads.
#
# == Why this does more than the other two processors ==
#
# ClaudeMcpConfigPostProcessor and CodexConfigTomlPostProcessor both ADJUST a
# file their AIR adapter already wrote. `@pulsemcp/air-adapter-pi` writes no MCP
# config at all — it is skills-only by design, and its own README says so
# ("MCP servers — Pi does not ship with an AIR-translatable MCP server registry.
# MCP server entries are ignored; the manifest records `mcpServers: []`").
#
# So `air prepare pi` runs with `--mcp-server <id>` for every configured server
# and produces nothing from them. If this processor only adjusted what AIR left
# behind, a Pi session would silently start with ZERO of its configured MCP
# servers — including, because the base class auto-injects them into a synthesized
# skeleton, only the Zimmer self-session server and nothing else. The session
# would look fine and be unable to reach a single tool it was configured with.
#
# This processor therefore seeds the server table from Zimmer's own catalog
# before delegating to the shared pipeline. `ServersConfig` is already the
# authoritative reader for those entries — it is what the UI and the REST API
# render from — so seeding reuses it rather than re-deriving anything.
#
# Everything after seeding is the ordinary shared behavior: subagent/self-session
# injection, retargeting Zimmer entries at this instance, stamping the session id,
# the elicitation address, `${VAR}` resolution and npx cache pinning all run
# unchanged, because they operate on the normalized server hash both formats share.
#
# If `adapter-pi` ever learns to translate MCP servers, the seeding here becomes
# redundant rather than wrong: #seed_catalog_servers! never overwrites an entry
# that is already present, so an AIR-written table wins.
class PiMcpConfigPostProcessor < RuntimeConfigPostProcessor
  include McpJsonConfigFormat

  MCP_CONFIG_FILENAME = McpJsonConfigFormat::MCP_CONFIG_FILENAME

  # The one timeout `pi-mcp-adapter` reads out of an `.mcp.json` server entry.
  # See #apply_startup_timeouts! for why this key and not a startup-specific one.
  REQUEST_TIMEOUT_KEY = "requestTimeoutMs"

  private

  # Seed the catalog's servers into the config the moment it is read, so every
  # later step in the shared pipeline sees them.
  #
  # This is the single seam both entry points go through (#post_process! and
  # #ensure_baseline!), which is why the override lives here rather than in
  # #post_process!. Ordering falls out of it for free: seeding happens before
  # injection, so #inject_self_session_server!'s dedup sees a catalog `zimmer`
  # entry the session actually configured and does not add a second, narrower one
  # beside it.
  #
  # On the #ensure_baseline! path this is a no-op — that path runs only for a
  # session with no MCP servers configured, so there is nothing to seed.
  def read_or_synthesize_config
    config = super
    seed_catalog_servers!(servers_map(config))
    config
  end

  # Write every MCP server the session is configured with into the server table.
  #
  # Reads through ServersConfig, the same catalog reader the UI renders from, so
  # a Pi session's servers cannot drift from what the session page says it has.
  #
  # An entry already in the table is left alone. Today nothing can put one there
  # (adapter-pi writes no config), but that is a property of the current adapter
  # rather than a guarantee, and "local wins" is the same precedence AIR itself
  # applies to skills.
  #
  # A configured server the catalog no longer knows is skipped with a warning
  # rather than raised on: the catalog evolves independently of the sessions that
  # reference it, and a removed server id must degrade one tool, not brick the
  # session's whole startup. This mirrors AirPrepareService#scrubbed_catalog_skills.
  def seed_catalog_servers!(servers)
    session.user_selected_mcp_servers.each do |name|
      next if servers.key?(name)

      server = ServersConfig.find(name)
      if server.nil?
        Rails.logger.warn(
          "[PiMcpConfigPostProcessor] Skipping unknown MCP server #{name.inspect} for session #{session.id}"
        )
        next
      end

      entry = catalog_entry_for(server)
      servers[name] = entry if entry
    end
  end

  # Translate a catalog Server into an `.mcp.json` entry.
  #
  # `${VAR}` interpolations are written through verbatim — the base class's
  # #resolve_secrets! step resolves them from SecretsLoader afterwards, which is
  # the single place that resolution is allowed to happen.
  #
  # An entry whose transport cannot be expressed is dropped with a warning rather
  # than written half-formed: a stdio entry with no command, or a remote entry
  # with no url, would make the Pi MCP adapter fail on connect with a message
  # that names nothing useful.
  def catalog_entry_for(server)
    if server.remote?
      return warn_unusable(server, "no url") if server.url.blank?

      entry = build_http_entry(url: server.url, headers: server.headers || {})
      # ServersConfig#remote? covers both `sse` and `streamable-http`, and they
      # are different wire protocols. Carrying the catalog's own type through
      # keeps an `sse` entry from being announced to the adapter as `http`.
      entry["type"] = server.type if server.type == "sse"
      entry
    else
      return warn_unusable(server, "no command") if server.command.blank?

      entry = { "type" => "stdio", "command" => server.command }
      entry["args"] = server.args.dup if server.args.present?
      entry["env"] = server.env.dup if server.env.present?
      entry
    end
  end

  # Give every stdio server the shared MCP startup budget, in the one spelling
  # Pi reads.
  #
  # Pi itself has no MCP: the client is the `pi-mcp-adapter` extension
  # (PiExtensions pins 2.32.1), and its knob is per-entry `requestTimeoutMs` in
  # the `.mcp.json` this class writes. Measured against the pinned extension by
  # pointing an `eager` stdio server at a `node` process that accepts the
  # connection and never answers `initialize`, and timing when the adapter gives
  # up:
  #
  #   no key set              63.4s   — the MCP SDK's own 60,000ms default
  #   requestTimeoutMs 30000  33.6s
  #   requestTimeoutMs 90000  93.6s
  #   requestTimeoutMs 180000 183.2s
  #
  # A flat ~3.4s of adapter startup sits on top of each; the budget itself is
  # honored exactly, and raising it above the SDK default works.
  #
  # Sixty seconds is more headroom than Codex's thirty, and still not obviously
  # enough: #pin_npx_caches_to_clone! guarantees a fresh clone's first launch
  # downloads every npx server from the registry, and the nine in `mcp.json`
  # installing at once cost 18s for the slowest on an idle production droplet.
  # Zimmer having no say in it at all was the actual gap
  # ([#844](https://github.com/tadasant/zimmer/issues/844)).
  #
  # This is the budget for the handshake, and on an `npx` entry the handshake is
  # not the whole cold start. The adapter intercepts a `command` of `npx`/`npm`
  # and resolves the package to a concrete bin path itself before any transport
  # exists (`resolveNpxBinary`, `npx-resolver.ts`), reading the npm cache of the
  # PI PROCESS rather than the entry's own `env` — so #pin_npx_caches_to_clone!
  # does not reach that lookup, and a miss there runs `npm exec` under the
  # adapter's own hard, non-configurable 30-second cap. Nothing written here
  # changes that phase; what it covers is the plain-`npx` fallback the adapter
  # drops to when its own resolution fails, plus every non-npx stdio server. See
  # the cold-clone section of docs/limitations.md.
  #
  # `requestTimeoutMs` is not startup-scoped, and that is a real consequence
  # rather than a detail: the adapter applies one budget to every request on the
  # connection, so a tool call on a Pi MCP server has three minutes rather than
  # the SDK's sixty seconds too. There is no connect-only key to write instead —
  # `buildRequestOptions` in the adapter's `server-manager.ts` builds a single
  # `RequestOptions` from this field and hands it to `client.connect` and to
  # every call after it. Widening both is the trade, and it goes the same way as
  # the startup one: a slow tool is recoverable, a tool killed mid-flight is not.
  #
  # Per-entry rather than the adapter's global `settings.requestTimeoutMs`,
  # which exists and would be one line shorter. The global covers HTTP entries
  # too, and those are the ones deliberately left out below.
  #
  # Only entries with a `command`, exactly as on Codex. The adapter has three
  # transports — `command`, `url` and `socket` — and the other two both reach a
  # server that is already running (for the auto-injected Zimmer entries, this
  # very process), so neither has a cold start to absorb and a wider budget
  # there would only delay reporting an endpoint that is simply unreachable.
  #
  # An entry that already names one keeps it, including a `0`, which the adapter
  # reads as "use the SDK default" — an explicit opt-out is still the operator's
  # call. A `mcp.json` catalog entry cannot express one (AIR's server schema has
  # no such field), so what this preserves is a value a repo wrote into its own
  # checked-in `.mcp.json`, which seeding merges around rather than replaces.
  def apply_startup_timeouts!(servers)
    timed = servers.filter_map do |name, entry|
      next unless entry.is_a?(Hash)
      next if entry["command"].blank?
      next if entry[REQUEST_TIMEOUT_KEY].present?

      entry[REQUEST_TIMEOUT_KEY] = McpStartupTimeout::MILLISECONDS
      name
    end

    return if timed.empty?

    Rails.logger.info "[#{self.class.name}] Set #{REQUEST_TIMEOUT_KEY}=#{McpStartupTimeout::MILLISECONDS} " \
      "on #{timed.size} stdio MCP server(s): #{timed.join(', ')}."
  end

  def warn_unusable(server, reason)
    Rails.logger.warn(
      "[PiMcpConfigPostProcessor] Skipping MCP server #{server.name.inspect} (#{reason}) " \
      "for session #{session.id}"
    )
    nil
  end
end
