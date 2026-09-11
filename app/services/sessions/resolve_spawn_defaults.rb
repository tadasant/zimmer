# frozen_string_literal: true

module Sessions
  # The create-time resolution every spawn surface shares: a session's runtime,
  # its model, and — when an agent root was named — the repository fields and
  # catalog defaults that come with it.
  #
  # The precedence is the one the whole app shares:
  #
  #   request value  →  agent root's declared value  →  AppSetting (the global
  #   base default set on the Settings page)  →  the hardcoded default
  #
  # It runs whether or not a root was named. Without one there is simply no root
  # tier and the chain falls straight through to AppSetting — which is the point:
  # the Settings page presents those values as global defaults, so a rootless
  # spawn (a bare `git_root`, through REST or MCP `start_session`) has to honor
  # them too. It always leaves an explicit model in `config`, so a spawn never
  # depends on a runtime-side default.
  #
  # Shared rather than duplicated because the two surfaces have drifted before:
  # REST honored the Settings-page defaults on a rootless create only after
  # zimmer#263, and MCP `start_session` had no rootless path at all until
  # zimmer#265.
  class ResolveSpawnDefaults
    # @param session [Session] an unsaved session already carrying whatever the
    #   caller named (git_root, branch, subdirectory, the artifact lists, config)
    # @param agent_root_name [String, nil] the catalog root the caller named, if any
    # @param explicit_runtime [Boolean] the caller named `agent_runtime`
    # @param explicit_branch [Boolean] the caller named `branch`
    # @param explicit_lists [Hash{Symbol=>Boolean}] which artifact lists the caller
    #   named — :mcp_servers, :skills, :hooks, :plugins. Only an OMITTED list falls
    #   back to the root's defaults: a `.blank?` test cannot tell omitted from
    #   explicitly-empty, so it would overwrite a caller's `[]` with the defaults,
    #   handing a session that asked for no MCP servers whatever the root declares.
    # @return [Session] the same session, with the defaults applied
    # @raise [AgentRootsConfig::AgentRootNotFoundError] when the named root is not in the catalog
    def self.call(session, agent_root_name: nil, explicit_runtime: false, explicit_branch: false, explicit_lists: {})
      new(session, agent_root_name: agent_root_name, explicit_runtime: explicit_runtime,
                   explicit_branch: explicit_branch, explicit_lists: explicit_lists).call
    end

    def initialize(session, agent_root_name:, explicit_runtime:, explicit_branch:, explicit_lists:)
      @session = session
      @agent_root_name = agent_root_name.to_s.strip.presence
      @explicit_runtime = explicit_runtime
      @explicit_branch = explicit_branch
      @explicit_lists = explicit_lists || {}
    end

    def call
      root = agent_root
      app_setting = AppSetting.current

      resolve_runtime!(root, app_setting)
      apply_root_defaults!(root) if root
      resolve_model!(root, app_setting)

      session
    end

    private

    attr_reader :session, :agent_root_name, :explicit_runtime, :explicit_branch, :explicit_lists

    def agent_root
      return nil if agent_root_name.blank?

      AgentRootsConfig.find!(agent_root_name)
    end

    # An explicit `agent_runtime` (the per-spawn override) wins and is left exactly
    # as given, so an unregistered value still fails the model's inclusion
    # validation rather than being silently corrected.
    def resolve_runtime!(root, app_setting)
      return if explicit_runtime

      session.agent_runtime = root&.default_runtime.presence ||
        app_setting.default_runtime.presence ||
        RuntimeRegistry::DEFAULT_RUNTIME
    end

    def apply_root_defaults!(root)
      session.git_root = root.url if session.git_root.blank?
      session.branch = root.default_branch || "main" unless explicit_branch
      session.subdirectory = root.subdirectory if session.subdirectory.blank? && root.subdirectory.present?
      session.mcp_servers = root.default_mcp_servers || [] unless explicit_lists[:mcp_servers]
      session.catalog_skills = root.default_skills || [] unless explicit_lists[:skills]
      session.catalog_hooks = root.default_hooks || [] unless explicit_lists[:hooks]
      session.catalog_plugins = root.default_plugins || [] unless explicit_lists[:plugins]
      # `root.name`, not the caller's spelling — see Session.create_from_agent_root!.
      session.metadata = (session.metadata || {}).merge("agent_root_key" => root.name)
    end

    # A root's default_model is typically a claude_code model, so applying it
    # unconditionally to a codex spawn would persist an invalid model: self-heal to
    # the global base default for the resolved runtime (which itself falls back to
    # that runtime's catalog default) whenever the root's model is not valid for
    # the runtime. With no root, that self-heal branch is the whole resolution.
    def resolve_model!(root, app_setting)
      return if session.config&.dig("model").present?

      model = root&.default_model
      unless ModelCatalog.valid_model?(session.agent_runtime, model)
        model = app_setting.resolved_default_model_for(session.agent_runtime)
      end
      session.config = (session.config || {}).merge("model" => model)
    end
  end
end
