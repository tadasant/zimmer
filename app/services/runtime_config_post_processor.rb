# frozen_string_literal: true

# Interface for runtime-specific post-processing of the MCP config that the AIR
# CLI writes during `air prepare`.
#
# AIR produces a runtime-native config file (`.mcp.json` for Claude,
# `.codex/config.toml` for Codex). Zimmer then applies a fixed set of conceptually
# runtime-agnostic tweaks to it:
#
#   1. Inject Zimmer's own MCP server when the root declares default_subagent_roots
#      (so parent roots can spawn subagent sessions).
#   2. Inject the self-session Zimmer MCP server unless an existing Zimmer server
#      already covers the self_session tool group.
#   3. Retarget Zimmer MCP server entries at the current Zimmer instance so a
#      local-dev or staging session orchestrates itself, not production.
#   4. Write the elicitation address (ELICITATION_REQUEST_URL / _SESSION_ID) into
#      every stdio server's own `env` table.
#   5. Resolve ${VAR} interpolations from SecretsLoader and rewrite npx commands.
#
# The injected servers are streamable-HTTP entries pointing at this instance's
# native /mcp endpoint (see McpController) — Zimmer speaks MCP itself, so nothing
# is spawned via npx to reach it.
#
# Steps 1-4 operate purely on the normalized server hash (`command`/`args`/`env`
# for stdio, `url`/header-table for http) that both formats share, so they live
# here as concrete shared logic. Steps tied to the file format and serialization
# (read/parse, server-table extraction, per-entry secret/npx resolution, write)
# are template-method hooks each concrete subclass implements
# (ClaudeMcpConfigPostProcessor for JSON, CodexConfigTomlPostProcessor for TOML),
# reusing the shared helpers SelfSessionInjector, SecretsInterpolator, and
# NpxPrefixRewriter for the format-agnostic value logic.
#
# Subclasses append the names of any auto-injected servers to
# #injected_mcp_servers so callers can record them in session metadata.
class RuntimeConfigPostProcessor
  attr_reader :session, :working_directory, :file_system, :injected_mcp_servers

  # @param session [Session] the session being prepared
  # @param working_directory [String] the session's working directory
  # @param file_system [FileSystemAdapter] injectable file system
  def initialize(session:, working_directory:, file_system:)
    @session = session
    @working_directory = working_directory
    @file_system = file_system
    @injected_mcp_servers = []
  end

  # Post-process the MCP config AIR wrote: inject servers, retarget, resolve
  # secrets, rewrite npx. Reads the runtime's config file, mutates it, writes it
  # back.
  #
  # AIR only writes a config file when the session has explicit MCP servers. A
  # session that is skills/hooks/plugins-only (so it takes this prepare! branch)
  # or a subagent-roots-only root can therefore reach here with no file on disk.
  # We must NOT skip in that case: the subagent Zimmer server (for a root with
  # default_subagent_roots) and the self-session Zimmer server are auto-injected
  # here, not by AIR, so gating injection on an AIR-produced file would silently
  # drop a parent root's only spawning server. Synthesize an empty skeleton when
  # the file is absent so injection + retarget + secret resolution + persist all
  # still run. See #ensure_baseline!, which shares this synthesize-when-absent
  # behavior.
  def post_process!
    config = read_or_synthesize_config
    servers = servers_map(config)

    inject_subagent_server!(servers)
    inject_self_session_server!(servers)
    retarget_zimmer_servers_to_current_env!(servers)
    inject_elicitation_env!(servers)
    resolve_and_rewrite!(servers)

    persist_config!(config)
  end

  # Ensure a baseline MCP config exists for sessions without explicit MCP
  # servers: create the config file if needed and inject the auto-injected Zimmer
  # servers so every session has basic self-management tools, and every parent
  # root with default_subagent_roots keeps its subagent-spawning server.
  #
  # The subagent Zimmer server must be injected here too (not only in #post_process!):
  # a root whose spawning capability comes purely from auto-injection (no
  # default_mcp_servers/skills/hooks/plugins) routes through this baseline path
  # on regeneration, and omitting the subagent injection here silently strips its
  # only start_session server. The subagent injection deduplicates the
  # self-session server (a full-surface Zimmer server with ALLOWED_AGENT_ROOTS
  # already covers the self_session tool group), so the two injections never
  # write duplicate Zimmer servers.
  def ensure_baseline!
    config = read_or_synthesize_config
    servers = servers_map(config)

    inject_subagent_server!(servers)
    inject_self_session_server!(servers)

    # Nothing injected means no Zimmer entry needs retarget/secret resolution: this
    # path runs only for a session with blank mcp_servers/skills/hooks/plugins, so
    # no catalog `zimmer` entry (which arrives via default_mcp_servers → the
    # post_process! branch) can be present for inject_subagent_server! to skip over.
    # A catalog entry that DID reach here would be left un-retargeted by this early
    # return — but by construction one cannot.
    return if injected_mcp_servers.empty?

    retarget_zimmer_servers_to_current_env!(servers)
    # A no-op today — everything reachable on this path is an auto-injected HTTP
    # Zimmer entry, and only stdio servers have an environment. It runs anyway so
    # the two paths stay identical: a stdio server that ever reaches here must not
    # be the one server on the instance that silently loses its approval address.
    inject_elicitation_env!(servers)
    resolve_and_rewrite!(servers)

    persist_config!(config)
  end

  private

  # Read the runtime's config file, or synthesize an empty skeleton when AIR did
  # not write one. Shared by #post_process! and #ensure_baseline! so both run the
  # auto-injections against a real server table regardless of whether an explicit
  # MCP server produced a file on disk.
  def read_or_synthesize_config
    file_system.exists?(config_path) ? parse_config(file_system.read(config_path)) : empty_config
  end

  # --- Format-specific hooks: each concrete runtime implements these. ---

  # @return [String] absolute path to the runtime's native config file.
  def config_path
    raise NotImplementedError, "#{self.class} must implement #config_path"
  end

  # @param raw [String] the file contents
  # @return [Hash] the parsed config
  def parse_config(_raw)
    raise NotImplementedError, "#{self.class} must implement #parse_config"
  end

  # @return [Hash] a fresh, empty config skeleton (used by #read_or_synthesize_config
  #   when AIR wrote no file)
  def empty_config
    raise NotImplementedError, "#{self.class} must implement #empty_config"
  end

  # @param config [Hash] the parsed config
  # @return [Hash] the mutable server table within the config, created if absent
  def servers_map(_config)
    raise NotImplementedError, "#{self.class} must implement #servers_map"
  end

  # The key an HTTP server entry stores its literal header table under
  # ("headers" for Claude's JSON, "http_headers" for Codex's TOML).
  # @return [String]
  def http_headers_key
    raise NotImplementedError, "#{self.class} must implement #http_headers_key"
  end

  # An HTTP MCP server entry in the runtime's native shape.
  # @return [Hash]
  def build_http_entry(url:, headers:)
    raise NotImplementedError, "#{self.class} must implement #build_http_entry"
  end

  # Remove any host-env forwarding rule for the given header, so a literal value
  # written by retargeting survives the rest of the pipeline. Only Codex has such
  # a table; Claude resolves header refs in place, so this is a no-op there.
  def drop_forwarded_credential_header!(_entry, _header)
    nil
  end

  # Remove any host-env forwarding rule for the given env var, for the same
  # reason as the header version above: a forwarding rule and a literal `env`
  # entry for one name is an ambiguity, and the literal one is the value Zimmer
  # means. Only Codex has such a table (`env_vars`); no-op for Claude.
  def drop_forwarded_env_var!(_entry, _name)
    nil
  end

  # Resolve ${VAR} interpolations and apply the npx --prefix rewrite to every
  # server entry, in the runtime's native field layout.
  def resolve_and_rewrite!(_servers)
    raise NotImplementedError, "#{self.class} must implement #resolve_and_rewrite!"
  end

  # @param config [Hash] the mutated config
  # @return [String] the serialized config contents
  def serialize_config(_config)
    raise NotImplementedError, "#{self.class} must implement #serialize_config"
  end

  # Write the config back, creating the parent directory first so runtimes whose
  # config lives in a subdirectory (e.g. Codex's .codex/config.toml) work even
  # when AIR did not create the file (ensure_baseline! path).
  def persist_config!(config)
    file_system.mkdir_p(File.dirname(config_path))
    file_system.write(config_path, serialize_config(config))
  end

  # --- Shared, format-agnostic logic. ---

  # When the root declares default_subagent_roots, inject Zimmer's MCP server
  # scoped to those roots (allowed_agent_roots), so parent roots can spawn
  # subagent sessions without explicitly listing a Zimmer MCP server in
  # default_mcp_servers. The entry is full-surface (no tool_groups), which is why
  # it also satisfies the self-session dedup below.
  #
  # Defensive against a name collision, mirroring SelfSessionInjector's dedup: if
  # the catalog already supplies a `zimmer` entry, leave it alone. In the native
  # MCP world every Zimmer variant is the SAME URL differentiated only by query
  # param, so blindly writing servers["zimmer"] would overwrite a catalog-provided
  # full-surface entry with our root-restricted one — silently narrowing
  # start_session's allowed_agent_roots with no error. Skipping keeps
  # start_session's full root surface, and retargeting still points the surviving
  # entry at the current instance.
  #
  # This trusts the catalog's naming convention: the bare `zimmer` key is reserved
  # for the unrestricted, full-surface server, while scoped variants are named
  # `zimmer-*` (see mcp.json). So an entry under this exact key is at least as
  # capable as the one we would inject. A plain key check is therefore enough —
  # unlike the self-session dedup, which must inspect tool_groups because it
  # matches every `zimmer*` name, not one reserved key.
  def inject_subagent_server!(servers)
    root = find_root
    return unless root&.default_subagent_roots&.any?

    name = SelfSessionInjector::SUBAGENT_SERVER_NAME
    if servers.key?(name)
      Rails.logger.info "[#{self.class.name}] Skipping subagent Zimmer server injection: " \
        "a catalog-provided '#{name}' entry is already present."
      return
    end

    servers[name] = build_http_entry(
      url: self_session_injector.endpoint_url(allowed_agent_roots: root.default_subagent_roots.join(",")),
      headers: self_session_injector.headers
    )

    injected_mcp_servers << name
  end

  def inject_self_session_server!(servers)
    existing = servers.filter_map do |name, entry|
      next unless entry.is_a?(Hash)
      { name: name, url: entry["url"] }
    end

    injected_name = self_session_injector.inject!(existing_servers: existing) do |name, url, headers|
      servers[name] = build_http_entry(url: url, headers: headers)
    end

    injected_mcp_servers << injected_name if injected_name
  end

  # Retarget every Zimmer MCP server entry at the current Zimmer instance.
  #
  # Why: a root's default_mcp_servers may reference a catalog entry whose URL
  # points at production Zimmer. A local-dev or staging session inheriting that
  # entry would orchestrate production instead of its own instance. Rewriting at
  # config-write time lets the same root work against any Zimmer environment
  # without per-env duplication in the catalog. Query-string scoping
  # (tool_groups / allowed_agent_roots) is preserved — only the origin and the
  # API key change.
  #
  # No-op in production, where the catalog's URLs already point at the instance
  # serving the session.
  def retarget_zimmer_servers_to_current_env!(servers)
    return if Rails.env.production?

    target = self_session_injector.self_target
    retargeted_any = false

    servers.each do |name, entry|
      next unless entry.is_a?(Hash)
      next unless self_session_injector.zimmer_server_name?(name)
      next if entry["url"].blank?

      entry["url"] = rebase_url(entry["url"], target[:base_url])
      # A catalog entry's API key arrives as a ${VAR} header ref, which a runtime
      # may carry as a host-env *forwarding* rule resolved later in the pipeline
      # (Codex's env_http_headers). Drop that rule: it names the catalog's var —
      # the production key — and would overwrite the key we are about to write.
      drop_forwarded_credential_header!(entry, SelfSessionInjector::API_KEY_HEADER)
      headers = entry[http_headers_key] ||= {}
      headers[SelfSessionInjector::API_KEY_HEADER] = target[:api_key]
      retargeted_any = true
    end

    # A blank API key means every MCP call 401s with a confusing auth error rather
    # than a clear configuration error. Warn at session-prep time instead.
    if retargeted_any && target[:api_key].blank?
      env_var = Rails.env == "staging" ? "ZIMMER_STAGING_API_KEY" : "ZIMMER_LOCAL_API_KEY"
      Rails.logger.warn "[#{self.class.name}] Retargeted Zimmer MCP servers in #{Rails.env} env with blank API key — " \
        "MCP calls will fail to authenticate. Set #{env_var} in your .env or credentials."
    end
  end

  # Write the approval endpoint's address into every stdio server's own `env`
  # table: ELICITATION_REQUEST_URL (where an approval request goes) and
  # ELICITATION_SESSION_ID (who is asking).
  #
  # Why here and not only in the spawn env: CliSpawnEnv sets both on the agent CLI
  # process, and Claude Code hands a stdio MCP server its own environment, so that
  # was enough there. Codex is not: it builds each server's environment from a
  # fixed whitelist (HOME, LANG, PATH, PWD, SHELL) plus exactly what the entry's
  # own `env`/`env_vars` name. Measured on codex-cli 0.146.0 — a stub stdio server
  # spawned by `codex exec` from a shell with both variables set received neither.
  # So on Codex every approval POST went to the client's baked-in default
  # (`http://zimmer/…`, which does not resolve in the agent container) and died as
  # `fetch failed`: a gate that fails closed and silently, indistinguishable from a
  # human denial. Writing the values into the config the runtime itself hands the
  # server is the one form of "reaching the server" both runtimes honor.
  #
  # Precedence: Zimmer's value wins over a catalog entry's `env` for these two keys
  # specifically. The address of Zimmer's own endpoint is Zimmer's to know, and a
  # catalog copy is a duplicate that can go stale without anything failing loudly —
  # which is exactly what happened: a `http://zimmer` left in a catalog entry
  # shadowed the injected URL for months. An operator who genuinely wants a
  # different endpoint still has the clone's `.env`, which wins here as it does for
  # the agent process (see #elicitation_env).
  #
  # Everything else in the entry is left alone: the values are MERGED into the
  # existing `env` table, never replacing it, because that table is where a
  # server's credentials live.
  def inject_elicitation_env!(servers)
    values = elicitation_env
    return if values.empty?

    written = servers.filter_map do |name, entry|
      next unless entry.is_a?(Hash)
      # stdio only — an HTTP/SSE entry (`url`, no `command`) has no child process
      # and therefore no environment to write.
      next if entry["command"].blank?

      env = (entry["env"] ||= {})
      # An `env` that is not a table is a malformed entry the runtime will reject
      # on its own terms; skip rather than making this step the thing that raises.
      next unless env.is_a?(Hash)

      values.each do |var, value|
        env[var] = value
        drop_forwarded_env_var!(entry, var)
      end
      name
    end

    return if written.empty?

    # Say so in the session log. The failure this fixes was silent on both ends —
    # the server could not reach the endpoint and nothing recorded that it had not
    # been told where the endpoint was. CliSpawnEnv logs the same for the agent
    # process; this is the other half.
    Rails.logger.info "[#{self.class.name}] Wrote #{ElicitationEndpoint::VARIABLES.join(' + ')} " \
      "into the env of #{written.size} stdio MCP server(s): #{written.join(', ')}"
  end

  # The elicitation variables as the agent process will see them, so a server's
  # env table and its parent agree: Zimmer's computed values, with the clone's
  # `.env` winning over them exactly as it does in CliSpawnEnv#apply_elicitation_env.
  #
  # The `.env` pass iterates the canonical names rather than what spawn_env
  # returned, so an operator's value is honored even for a name Zimmer itself has
  # nothing to say about (a session-less caller sets no session tag).
  def elicitation_env
    values = ElicitationEndpoint.spawn_env(session_id: session&.id)
    dotenv = EnvFile.load(working_directory, file_system: file_system)

    ElicitationEndpoint::VARIABLES.each do |name|
      values[name] = dotenv[name] if dotenv[name].present?
    end
    values
  rescue StandardError => e
    # A broken .env or an unresolvable base URL must not fail session prep; losing
    # the address is a degraded gate, losing the session is a dead session.
    Rails.logger.warn "[#{self.class.name}] Skipping elicitation env injection: #{e.class}: #{e.message}"
    {}
  end

  # Swap a URL's origin for the current instance's, keeping path and query.
  def rebase_url(url, base_url)
    uri = URI.parse(url.to_s)
    base = URI.parse(base_url.to_s)
    uri.scheme = base.scheme
    uri.host = base.host
    uri.port = base.port
    uri.to_s
  rescue URI::InvalidURIError
    url
  end

  # Look up the AgentRoot object for this session.
  def find_root
    root_name = find_root_name
    return unless root_name.present?
    AgentRootsConfig.find(root_name)
  end

  # Determine the agent root key for this session. Prefers the explicit key
  # stored in session metadata at creation time; falls back to reverse-lookup
  # by URL + subdirectory.
  def find_root_name
    session.metadata&.dig("agent_root_key") ||
      AgentRootsConfig.find_for_session(session)&.name
  end

  def self_session_injector
    @self_session_injector ||= SelfSessionInjector.new(secrets_interpolator: secrets_interpolator)
  end

  def secrets_interpolator
    @secrets_interpolator ||= SecretsInterpolator.new
  end
end
