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

  def warn_unusable(server, reason)
    Rails.logger.warn(
      "[PiMcpConfigPostProcessor] Skipping MCP server #{server.name.inspect} (#{reason}) " \
      "for session #{session.id}"
    )
    nil
  end
end
