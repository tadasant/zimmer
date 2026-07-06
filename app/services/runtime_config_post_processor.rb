# frozen_string_literal: true

# Interface for runtime-specific post-processing of the MCP config that the AIR
# CLI writes during `air prepare`.
#
# AIR produces a runtime-native config file (`.mcp.json` for Claude,
# `.codex/config.toml` for Codex). Zimmer then applies a fixed set of conceptually
# runtime-agnostic tweaks to it:
#
#   1. Inject an agent-orchestrator MCP server when the root declares
#      default_subagent_roots (so parent roots can spawn subagent sessions).
#   2. Inject a self-session Zimmer MCP server unless an existing Zimmer server already
#      covers the self_session tool group.
#   3. Retarget agent-orchestrator-* server entries at the current Zimmer instance
#      so a local-dev or staging session orchestrates itself, not production.
#   4. Resolve ${VAR} interpolations from SecretsLoader and rewrite npx commands.
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
  # back. No-op when the file does not exist.
  def post_process!
    return unless file_system.exists?(config_path)

    config = parse_config(file_system.read(config_path))
    servers = servers_map(config)

    inject_subagent_ao_server!(servers)
    inject_self_session_ao_server!(servers)
    retarget_ao_servers_to_current_env!(servers)
    resolve_and_rewrite!(servers)

    persist_config!(config)
  end

  # Ensure a baseline MCP config exists for sessions without explicit MCP
  # servers: create the config file if needed and inject the self-session Zimmer
  # server so every session has basic self-management tools.
  def ensure_baseline!
    config = file_system.exists?(config_path) ? parse_config(file_system.read(config_path)) : empty_config
    servers = servers_map(config)

    inject_self_session_ao_server!(servers)

    return if injected_mcp_servers.empty?

    retarget_ao_servers_to_current_env!(servers)
    resolve_and_rewrite!(servers)

    persist_config!(config)
  end

  private

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

  # @return [Hash] a fresh, empty config skeleton (used by ensure_baseline!)
  def empty_config
    raise NotImplementedError, "#{self.class} must implement #empty_config"
  end

  # @param config [Hash] the parsed config
  # @return [Hash] the mutable server table within the config, created if absent
  def servers_map(_config)
    raise NotImplementedError, "#{self.class} must implement #servers_map"
  end

  # Build the native server entry for a catalog server (stdio or http).
  # @param catalog_server [ServersConfig::Server]
  # @return [Hash]
  def build_server_entry(_catalog_server)
    raise NotImplementedError, "#{self.class} must implement #build_server_entry"
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

  # When the root declares default_subagent_roots, inject an agent-orchestrator MCP server
  # with ALLOWED_AGENT_ROOTS set to the declared subagent roots. This lets parent roots
  # spawn subagent sessions without explicitly listing an Zimmer MCP server in default_mcp_servers.
  def inject_subagent_ao_server!(servers)
    root = find_root
    return unless root&.default_subagent_roots&.any?

    allowed_roots = root.default_subagent_roots.join(",")
    target = self_session_injector.ao_self_target

    servers["agent-orchestrator"] = {
      "command" => "npx",
      "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
      "env" => {
        "AGENT_ORCHESTRATOR_BASE_URL" => target[:base_url],
        "AGENT_ORCHESTRATOR_API_KEY" => target[:api_key],
        "ALLOWED_AGENT_ROOTS" => allowed_roots
      }
    }

    injected_mcp_servers << "agent-orchestrator"
  end

  def inject_self_session_ao_server!(servers)
    existing = servers.filter_map do |name, entry|
      next unless entry.is_a?(Hash)
      { name: name, tool_groups: entry.dig("env", "TOOL_GROUPS") }
    end

    injected_key = self_session_injector.inject!(existing_ao_servers: existing) do |catalog_key, catalog_server|
      servers[catalog_key] = build_server_entry(catalog_server)
    end

    injected_mcp_servers << injected_key if injected_key
  end

  # Retarget every agent-orchestrator-* MCP server entry at the current Zimmer
  # instance's BASE_URL and API_KEY.
  #
  # Why: roots.json default_mcp_servers references the prod-suffixed catalog
  # entries (e.g. `agent-orchestrator-prod`), and the catalog entries default
  # to https://zimmer.example.com. A local-dev or staging session inheriting that
  # default would orchestrate production Zimmer instead of its own instance. We
  # rewrite at config-write time so the same root works against any Zimmer
  # environment without per-env duplication in the catalog.
  #
  # The TOOL_GROUPS / API_KEY env keys live in the literal `env` table in both
  # formats (they are not same-named ${VAR} refs, so AIR never converts them to
  # Codex host-env forwarding), so this single implementation serves both.
  #
  # No-op in production — the catalog's prod defaults are already correct.
  def retarget_ao_servers_to_current_env!(servers)
    return if Rails.env.production?

    target = self_session_injector.ao_self_target
    retargeted_any = false
    servers.each do |name, entry|
      next unless name.to_s.start_with?("agent-orchestrator")
      next unless entry.is_a?(Hash)

      env = entry["env"] ||= {}
      env["AGENT_ORCHESTRATOR_BASE_URL"] = target[:base_url]
      env["AGENT_ORCHESTRATOR_API_KEY"] = target[:api_key]
      retargeted_any = true
    end

    # Blank API_KEY means the spawned MCP server will fail to authenticate with a
    # confusing 401 rather than a clear configuration error. Warn so the dev
    # notices at session-prep time instead of at first tool call.
    if retargeted_any && target[:api_key].blank?
      env_var = Rails.env == "staging" ? "AGENT_ORCHESTRATOR_STAGING_API_KEY" : "AGENT_ORCHESTRATOR_LOCAL_API_KEY"
      Rails.logger.warn "[#{self.class.name}] Retargeted agent-orchestrator-* servers in #{Rails.env} env with blank API_KEY — " \
        "spawned MCP servers will fail to authenticate. Set #{env_var} in your .env or credentials."
    end
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
