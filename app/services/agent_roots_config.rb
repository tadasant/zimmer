# frozen_string_literal: true

# Service class for managing agent root configurations.
# Reads agent root entries from AirCatalogService, which discovers them via air.json.
class AgentRootsConfig
  class AgentRootNotFoundError < StandardError; end
  class ConfigurationError < StandardError; end

  # The default agent root selected on the new session form
  DEFAULT_ROOT = ENV.fetch("AO_DEFAULT_AGENT_ROOT", "general-agent").freeze

  # Agent root configuration object
  class AgentRoot
    attr_reader :name, :display_name, :description, :url, :default_branch, :subdirectory, :default_goal, :default_mcp_servers, :default_skills, :default_hooks, :default_plugins, :default_subagent_roots, :user_invocable, :default_model, :default_runtime

    # @param app_setting [AppSetting, AppSetting::NULL, nil] the global base
    #   defaults. Passed in by build_roots so the singleton is read once per
    #   catalog build rather than once per root (avoiding an N+1). When nil
    #   (direct construction, e.g. in tests) it is fetched here.
    def initialize(name, config, app_setting: nil)
      @name = name
      @display_name = config["display_name"]
      @description = config["description"]
      @url = config["url"]
      @default_branch = config["default_branch"] || "main"
      @subdirectory = config["subdirectory"]
      @default_goal = config["default_goal"]
      @default_mcp_servers = config["default_mcp_servers"] || []
      @default_skills = config["default_skills"] || []
      @default_hooks = config["default_hooks"] || []
      @default_plugins = config["default_plugins"] || []
      @default_subagent_roots = config["default_subagent_roots"] || []
      @user_invocable = config.fetch("user_invocable", true)

      app_setting ||= AppSetting.current

      # Resolution precedence for both runtime and model:
      #   roots.json explicit value  →  global base default (AppSetting)  →  hardcoded default
      # The catalog's explicit value always wins (`config["..."] ||`), so this
      # never overrides a root that pins its own runtime/model. The global base
      # only fills in when the catalog leaves the field blank — the single place
      # the "everything undefined" default lives, keeping the JSON sparse.
      @default_runtime = config["default_runtime"].presence ||
        app_setting.default_runtime.presence ||
        RuntimeRegistry::DEFAULT_RUNTIME
      @default_model = config["default_model"].presence ||
        app_setting.resolved_default_model_for(@default_runtime)
    end

    # All catalog-managed roots are not custom
    def custom?
      false
    end

    # Check if this agent root can be directly invoked by users
    def user_invocable?
      user_invocable == true
    end

    # Convert to hash representation.
    # Includes `custom` and `default` for REST API backwards compatibility
    # (custom is always false since all roots are catalog-managed;
    # default is derived from DEFAULT_ROOT constant).
    def to_h
      {
        name: name,
        display_name: display_name,
        description: description,
        url: url,
        default_branch: default_branch,
        subdirectory: subdirectory,
        custom: false,
        default_goal: default_goal,
        default: name == AgentRootsConfig::DEFAULT_ROOT,
        default_mcp_servers: default_mcp_servers,
        default_skills: default_skills,
        default_hooks: default_hooks,
        default_plugins: default_plugins,
        user_invocable: user_invocable?,
        default_model: default_model,
        default_runtime: default_runtime
      }
    end

    def to_json(*args)
      to_h.to_json(*args)
    end
  end

  class << self
    # Get all available agent roots (auto-reloads via AirCatalogService TTL).
    def all
      build_roots
    end

    def find(name)
      all.find { |agent_root| agent_root.name == name }
    end

    def find!(name)
      find(name) || raise(AgentRootNotFoundError, "Agent root '#{name}' not found in catalog")
    end

    # Find the agent root matching a session's git_root and subdirectory.
    # Prefers the explicit agent_root_key from session metadata when available.
    def find_for_session(session)
      key = session.metadata&.dig("agent_root_key")
      if key.present?
        root = find(key)
        return root if root
      end

      all.find { |ar| ar.url == session.git_root && ar.subdirectory.to_s == session.subdirectory.to_s }
    end

    def names
      all.map(&:name)
    end

    def user_invocable
      all.select(&:user_invocable?)
    end

    # Roots whose resolved runtime matches the given runtime. Because absence of
    # `default_runtime` resolves to RuntimeRegistry::DEFAULT_RUNTIME, calling this
    # with the default runtime returns every existing root (the catalog is sparse).
    # A blank/nil argument resolves to the default runtime, mirroring RuntimeRegistry.for.
    def for_runtime(runtime)
      target = runtime.presence&.to_s || RuntimeRegistry::DEFAULT_RUNTIME
      all.select { |agent_root| agent_root.default_runtime == target }
    end

    def default
      find(DEFAULT_ROOT) || all.min_by(&:name)
    end

    # Unique default models declared across roots. Pass `runtime:` to scope to
    # roots resolving to that runtime; nil returns every root's default model.
    # Note: this reflects what roots *declare* as defaults — the authoritative
    # set of *selectable* models per runtime lives in ModelCatalog.
    def available_models(runtime: nil)
      scope = runtime ? for_runtime(runtime) : all
      scope.map(&:default_model).uniq.sort
    end

    # Every registered runtime, in RuntimeRegistry order. Drives the new-session
    # runtime selector, which is decoupled from what roots declare as their
    # default_runtime: a root's runtime is per-session state (an override on
    # sessions.agent_runtime), so any root can be launched under any registered
    # runtime. The selectable runtimes are therefore the full registry, not the
    # subset some root happens to default to.
    def available_runtimes
      RuntimeRegistry.registered_runtimes
    end

    def exists?(name)
      find(name).present?
    end

    def reload!
      AirCatalogService.reload!
      all
    end

    def config
      AirCatalogService.entries_for(:roots)
    end

    private

    def build_roots
      app_setting = AppSetting.current
      AirCatalogService.entries_for(:roots).map { |name, entry| AgentRoot.new(name, entry, app_setting: app_setting) }
    rescue AirCatalogService::CatalogError => e
      # AirCatalogService serves a last-known-good catalog (in-memory or persisted
      # snapshot) whenever a resolve fails, so reaching here means even that
      # fallback was exhausted — no catalog has ever resolved successfully. That is
      # genuinely broken (every session start, including zimmer-router, will fail) and
      # warrants an alert, not a warning.
      Rails.logger.error "[AgentRootsConfig] catalog unavailable with no last-known-good fallback: #{e.message}"
      []
    end
  end
end
