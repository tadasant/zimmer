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
  # It is the only implementation. Every way a new session is built goes through
  # it — POST /api/v1/sessions, MCP `start_session`, the web new-session form, and
  # Session.create_from_agent_root! (the quick prompt, the chat bubble, every
  # trigger fire). Each of those keeps only its own concerns: permitting params,
  # coercing arguments, and deciding what "the caller named this" means on its
  # surface. The four used to carry their own copies, and three closed bugs
  # (zimmer#310, #331, #81) were each one copy disagreeing with the others
  # (zimmer#454). `test/integration/spawn_defaults_conformance_test.rb` pins
  # that the four agree.
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
    #   What counts as "named" is the caller's decision, not this service's — see
    #   Session.create_from_agent_root!, where an empty list is deliberately not.
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
      root ? apply_root_defaults!(root) : apply_rootless_defaults!
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
      # The RESOLVED root's name, not the caller's spelling of it. An artifact has
      # three legal spellings since zimmer#208 (canonical token, qualified
      # `@scope/id`, bare short id), and what is stored has to be the one
      # AgentRootsConfig.find, the MCP allowlists and `air prepare --root` all key
      # on — the canonical token. See ArtifactIdentity.
      session.metadata = (session.metadata || {}).merge("agent_root_key" => root.name)
    end

    # With no root the branch has no root tier either, so a blank one is "main" —
    # the column default, restated because a form that posts `branch: ""` has
    # already overwritten it.
    def apply_rootless_defaults!
      session.branch = "main" if session.branch.blank? && !explicit_branch
      record_rootless_mcp_servers!
    end

    # A rootless spawn has no root defaults for an omitted mcp_servers to fall back
    # to, so omitted IS none — and that has to be recorded as deliberate.
    # Otherwise McpServerBackfill reads the empty column as a failed catalog
    # resolve and, when the git_root happens to equal a catalog root's URL (which
    # is all Session#resolved_agent_root's fallback arm matches on), hands the
    # session that root's MCP servers at job start: servers the caller never asked
    # for, on a path whose premise is that no catalog entry applies. A caller that
    # DID name a non-empty list clears the marker here for the same reason.
    def record_rootless_mcp_servers!
      session.record_explicit_mcp_servers(session.mcp_servers)
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
