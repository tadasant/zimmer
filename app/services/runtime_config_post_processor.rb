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
#   4. Resolve ${VAR} interpolations from SecretsLoader and rewrite npx commands.
#
# The injected servers are streamable-HTTP entries pointing at this instance's
# native /mcp endpoint (see McpController) — Zimmer speaks MCP itself, so nothing
# is spawned via npx to reach it.
#
# Steps 1-3 operate purely on the normalized server hash (`command`/`args`/`env`
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

    return if injected_mcp_servers.empty?

    retarget_zimmer_servers_to_current_env!(servers)
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
  # start_session's allowed_agent_roots with no error. The catalog entry is at
  # least as capable (it is the unrestricted, full-surface server), so skipping
  # keeps start_session's full root surface. Retargeting still points it at the
  # current instance.
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
