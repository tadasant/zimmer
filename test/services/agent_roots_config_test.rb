# frozen_string_literal: true

require "test_helper"

class AgentRootsConfigTest < ActiveSupport::TestCase
  test "loads agent roots from config file" do
    agent_roots = AgentRootsConfig.all

    assert agent_roots.is_a?(Array)
    assert agent_roots.size > 0
    assert agent_roots.all? { |agent_root| agent_root.is_a?(AgentRootsConfig::AgentRoot) }
  end

  test "finds agent root by name" do
    agent_root = AgentRootsConfig.find("agent-orchestrator")

    assert_not_nil agent_root
    assert_equal "agent-orchestrator", agent_root.name
    assert_equal "Agent Orchestrator", agent_root.display_name
  end

  test "returns nil for non-existent agent root" do
    agent_root = AgentRootsConfig.find("non-existent")

    assert_nil agent_root
  end

  test "finds agent root by name with bang" do
    agent_root = AgentRootsConfig.find!("agent-orchestrator")

    assert_not_nil agent_root
    assert_equal "agent-orchestrator", agent_root.name
  end

  test "raises error for non-existent agent root with bang" do
    assert_raises(AgentRootsConfig::AgentRootNotFoundError) do
      AgentRootsConfig.find!("non-existent")
    end
  end

  test "returns list of agent root names" do
    names = AgentRootsConfig.names

    assert names.is_a?(Array)
    assert names.size > 0
    assert names.all? { |name| name.is_a?(String) }
    assert_includes names, "agents"
  end

  test "checks if agent root exists" do
    assert AgentRootsConfig.exists?("agents")
    refute AgentRootsConfig.exists?("non-existent")
  end

  test "agent root has correct attributes" do
    agent_root = AgentRootsConfig.find("agent-orchestrator")

    assert_equal "agent-orchestrator", agent_root.name
    assert_equal "Agent Orchestrator", agent_root.display_name
    assert agent_root.description.present?
    assert_equal "https://github.com/tadasant/zimmer-catalog.git", agent_root.url
    assert_equal "main", agent_root.default_branch
    assert_equal "agents/agent-orchestrator", agent_root.subdirectory
  end

  test "agent root converts to hash" do
    agent_root = AgentRootsConfig.find("agent-orchestrator")
    hash = agent_root.to_h

    assert_equal "agent-orchestrator", hash[:name]
    assert_equal "Agent Orchestrator", hash[:display_name]
    assert hash[:description].present?
    assert_equal "https://github.com/tadasant/zimmer-catalog.git", hash[:url]
    assert_equal "main", hash[:default_branch]
    assert_equal "agents/agent-orchestrator", hash[:subdirectory]
    assert_equal false, hash[:custom]
    assert_equal false, hash[:default]
  end

  test "agent root converts to json" do
    agent_root = AgentRootsConfig.find("agent-orchestrator")
    json = JSON.parse(agent_root.to_json)

    assert_equal "agent-orchestrator", json["name"]
    assert_equal "Agent Orchestrator", json["display_name"]
  end

  test "reloads configuration" do
    # Call all to load config
    initial_agent_roots = AgentRootsConfig.all

    # Reload
    reloaded_agent_roots = AgentRootsConfig.reload!

    assert_equal initial_agent_roots.size, reloaded_agent_roots.size
  end

  # TTL/cache invalidation lives in AirCatalogService and is exercised in
  # AirCatalogServiceTest. AgentRootsConfig only delegates.

  test "returns default agent root" do
    default_agent_root = AgentRootsConfig.default

    assert_not_nil default_agent_root
    assert default_agent_root.is_a?(AgentRootsConfig::AgentRoot)
  end

  test "default agent root is general-agent via DEFAULT_ROOT constant" do
    default_agent_root = AgentRootsConfig.default

    assert_equal "general-agent", default_agent_root.name
    assert_equal "general-agent", AgentRootsConfig::DEFAULT_ROOT
  end

  test "default falls back to alphabetical first when DEFAULT_ROOT not found" do
    # Temporarily override the constant to a non-existent root
    original = AgentRootsConfig::DEFAULT_ROOT
    AgentRootsConfig.send(:remove_const, :DEFAULT_ROOT)
    AgentRootsConfig.const_set(:DEFAULT_ROOT, "non-existent-root")

    default_agent_root = AgentRootsConfig.default
    assert_equal AgentRootsConfig.all.min_by(&:name).name, default_agent_root.name
  ensure
    AgentRootsConfig.send(:remove_const, :DEFAULT_ROOT)
    AgentRootsConfig.const_set(:DEFAULT_ROOT, original)
  end

  test "user_invocable scope excludes subagent roots" do
    user_invocable_roots = AgentRootsConfig.user_invocable
    all_roots = AgentRootsConfig.all

    assert user_invocable_roots.size < all_roots.size, "user_invocable should return fewer roots than all"
    assert user_invocable_roots.all?(&:user_invocable?), "all returned roots should be user_invocable"
    refute user_invocable_roots.any? { |r| r.name == "catalog-mgmt-proctor" }, "subagent should not be included"
  end

  test "user_invocable defaults to true" do
    agent_root = AgentRootsConfig.find("agent-orchestrator")

    assert agent_root.user_invocable?
  end

  test "user_invocable is false for subagent roots" do
    agent_root = AgentRootsConfig.find("catalog-mgmt-proctor")

    assert_not_nil agent_root
    refute agent_root.user_invocable?
  end

  test "user_invocable is included in to_h" do
    agent_root = AgentRootsConfig.find("agent-orchestrator")
    hash = agent_root.to_h

    assert_includes hash.keys, :user_invocable
    assert_equal true, hash[:user_invocable]
  end

  test "subagent roots have correct default_mcp_servers" do
    agent_root = AgentRootsConfig.find("catalog-mgmt-proctor")

    # The minimal Zimmer catalog wires no plugin/server membership onto the demo
    # subagent roots, so default_mcp_servers resolves to an empty array. Assert the
    # shape and the empty default rather than specific servers.
    assert_not_nil agent_root
    assert agent_root.default_mcp_servers.is_a?(Array)
    assert_empty agent_root.default_mcp_servers
  end

  test "subagent roots have correct default_skills" do
    agent_root = AgentRootsConfig.find("catalog-mgmt-configs")

    # No skills are wired onto the demo subagent roots in the minimal catalog.
    assert_not_nil agent_root
    assert agent_root.default_skills.is_a?(Array)
    assert_empty agent_root.default_skills
  end

  test "default_model defaults to opus when not specified" do
    agent_root = AgentRootsConfig.find("agent-orchestrator")

    assert_equal "opus", agent_root.default_model
  end

  test "catalog-management parent root uses opus model" do
    agent_root = AgentRootsConfig.find("catalog-management")
    assert_equal "opus", agent_root.default_model
  end

  test "catalog-mgmt subagent roots use sonnet model" do
    %w[catalog-mgmt-configs catalog-mgmt-research catalog-mgmt-save catalog-mgmt-proctor].each do |root_name|
      agent_root = AgentRootsConfig.find(root_name)
      assert_equal "sonnet", agent_root.default_model, "Expected #{root_name} to use sonnet"
    end
  end

  test "default_model is included in to_h" do
    agent_root = AgentRootsConfig.find("catalog-management")
    hash = agent_root.to_h

    assert_includes hash.keys, :default_model
    assert_equal "opus", hash[:default_model]
  end

  test "default_runtime resolves to claude_code when not specified" do
    config = { "url" => "https://github.com/test/repo.git" }
    agent_root = AgentRootsConfig::AgentRoot.new("test-root", config)
    assert_equal RuntimeRegistry::DEFAULT_RUNTIME, agent_root.default_runtime
    assert_equal "claude_code", agent_root.default_runtime
  end

  test "default_runtime is read from config when present" do
    config = { "url" => "https://github.com/test/repo.git", "default_runtime" => "codex" }
    agent_root = AgentRootsConfig::AgentRoot.new("test-root", config)
    assert_equal "codex", agent_root.default_runtime
  end

  test "global app_setting fills in runtime and model when the root declares neither" do
    config = { "url" => "https://github.com/test/repo.git" }
    app_setting = AppSetting.new(default_runtime: "codex", default_model: "gpt-5.5")
    agent_root = AgentRootsConfig::AgentRoot.new("test-root", config, app_setting: app_setting)

    assert_equal "codex", agent_root.default_runtime
    assert_equal "gpt-5.5", agent_root.default_model
  end

  test "explicit roots.json runtime always wins over the global app_setting" do
    config = { "url" => "https://github.com/test/repo.git", "default_runtime" => "claude_code" }
    app_setting = AppSetting.new(default_runtime: "codex", default_model: "gpt-5.5")
    agent_root = AgentRootsConfig::AgentRoot.new("test-root", config, app_setting: app_setting)

    # Root pins claude_code; the global codex/gpt-5.5 must not override it, and the
    # global gpt-5.5 model is invalid for claude_code so it self-heals to opus.
    assert_equal "claude_code", agent_root.default_runtime
    assert_equal "opus", agent_root.default_model
  end

  test "explicit roots.json model always wins over the global app_setting" do
    config = { "url" => "https://github.com/test/repo.git", "default_model" => "sonnet" }
    app_setting = AppSetting.new(default_runtime: "codex", default_model: "gpt-5.5")
    agent_root = AgentRootsConfig::AgentRoot.new("test-root", config, app_setting: app_setting)

    assert_equal "sonnet", agent_root.default_model
  end

  test "a global runtime with no global model resolves to that runtime's catalog default" do
    config = { "url" => "https://github.com/test/repo.git" }
    app_setting = AppSetting.new(default_runtime: "codex", default_model: nil)
    agent_root = AgentRootsConfig::AgentRoot.new("test-root", config, app_setting: app_setting)

    assert_equal "codex", agent_root.default_runtime
    assert_equal ModelCatalog.default_for("codex"), agent_root.default_model
  end

  test "a blank global app_setting preserves the hardcoded claude_code/opus defaults" do
    config = { "url" => "https://github.com/test/repo.git" }
    app_setting = AppSetting.new(default_runtime: nil, default_model: nil)
    agent_root = AgentRootsConfig::AgentRoot.new("test-root", config, app_setting: app_setting)

    assert_equal "claude_code", agent_root.default_runtime
    assert_equal "opus", agent_root.default_model
  end

  test "default_runtime is included in to_h with resolved value" do
    config = { "url" => "https://github.com/test/repo.git" }
    agent_root = AgentRootsConfig::AgentRoot.new("test-root", config)
    hash = agent_root.to_h

    assert_includes hash.keys, :default_runtime
    assert_equal "claude_code", hash[:default_runtime]
  end

  test "for_runtime claude_code returns the same set as all today" do
    # The catalog is sparse (no entry declares default_runtime), so every root
    # resolves to claude_code and for_runtime("claude_code") == all.
    assert_equal AgentRootsConfig.all.map(&:name).sort,
      AgentRootsConfig.for_runtime("claude_code").map(&:name).sort
  end

  test "for_runtime with blank argument resolves to the default runtime" do
    assert_equal AgentRootsConfig.for_runtime("claude_code").map(&:name).sort,
      AgentRootsConfig.for_runtime(nil).map(&:name).sort
  end

  test "for_runtime excludes roots whose runtime does not match" do
    # No catalog root declares codex today, so codex filtering yields none.
    assert_empty AgentRootsConfig.for_runtime("codex")
  end

  test "available_models returns unique sorted model identifiers" do
    models = AgentRootsConfig.available_models

    assert models.is_a?(Array)
    assert_includes models, "opus"
    assert_includes models, "sonnet"
    assert_equal models.uniq.sort, models
  end

  test "available_models scoped to claude_code matches unscoped today" do
    # Every catalog root resolves to claude_code, so scoping is a no-op now but
    # provides the seam for runtime-specific catalogs later.
    assert_equal AgentRootsConfig.available_models,
      AgentRootsConfig.available_models(runtime: "claude_code")
  end

  test "available_models scoped to a runtime with no roots is empty" do
    assert_empty AgentRootsConfig.available_models(runtime: "codex")
  end

  test "available_runtimes returns every registered runtime, not the root-defaults intersection" do
    runtimes = AgentRootsConfig.available_runtimes

    # The selector is decoupled from root defaults: it offers every registered
    # runtime, even ones no root declares as its default_runtime (e.g. codex).
    assert_equal RuntimeRegistry.registered_runtimes, runtimes
    assert_includes runtimes, "claude_code"
    assert_includes runtimes, "codex"

    # codex is offered despite no root defaulting to it.
    assert_empty AgentRootsConfig.for_runtime("codex"),
      "precondition: no root should declare codex as its default_runtime"
  end

  test "find_for_session matches by agent_root_key in metadata" do
    session = sessions(:active_session)
    session.update!(metadata: (session.metadata || {}).merge("agent_root_key" => "agent-orchestrator"))

    result = AgentRootsConfig.find_for_session(session)

    assert_not_nil result
    assert_equal "agent-orchestrator", result.name
  end

  test "find_for_session falls back to url and subdirectory match" do
    session = sessions(:active_session)
    session.update!(
      git_root: "https://github.com/tadasant/zimmer-catalog.git",
      subdirectory: "agents/agent-orchestrator",
      metadata: {}
    )

    result = AgentRootsConfig.find_for_session(session)

    assert_not_nil result
    assert_equal "agent-orchestrator", result.name
  end

  test "find_for_session returns nil when no match" do
    session = sessions(:active_session)
    session.update!(
      git_root: "https://github.com/unknown/repo.git",
      subdirectory: nil,
      metadata: {}
    )

    result = AgentRootsConfig.find_for_session(session)

    assert_nil result
  end

  test "default_hooks defaults to empty array when not specified" do
    # Instantiate directly with a config that omits default_hooks to isolate
    # the `|| []` fallback from whatever the live roots.json catalog declares.
    agent_root = AgentRootsConfig::AgentRoot.new("stub-root", {})

    assert_equal [], agent_root.default_hooks
  end

  test "default_hooks is included in to_h" do
    agent_root = AgentRootsConfig::AgentRoot.new("stub-root", {})
    hash = agent_root.to_h

    assert_includes hash.keys, :default_hooks
    assert_equal [], hash[:default_hooks]
  end

  test "default_subagent_roots is parsed for parent roots" do
    agent_root = AgentRootsConfig.find("catalog-management")

    assert_not_nil agent_root.default_subagent_roots
    assert agent_root.default_subagent_roots.is_a?(Array)
    assert_includes agent_root.default_subagent_roots, "catalog-mgmt-research"
    assert_includes agent_root.default_subagent_roots, "catalog-mgmt-configs"
    assert_includes agent_root.default_subagent_roots, "catalog-mgmt-proctor"
    assert_includes agent_root.default_subagent_roots, "catalog-mgmt-save"
  end

  test "default_subagent_roots is empty for roots without subagents" do
    agent_root = AgentRootsConfig.find("agent-orchestrator")

    assert_equal [], agent_root.default_subagent_roots
  end

  test "default_plugins defaults to empty array when not specified" do
    agent_root = AgentRootsConfig.find("agents")

    assert_equal [], agent_root.default_plugins
  end

  test "default_plugins reflects the catalog when specified" do
    agent_root = AgentRootsConfig.find("agent-orchestrator")

    # Resolved membership is an unordered set — AgentRootsConfig loads it straight
    # into an attribute with no order logic, and `air resolve` derives ordering from
    # artifact-file order (plugins.json), not the root entry. Compare sorted.
    assert_equal [ "ci-workflow", "screenshots-videos" ], agent_root.default_plugins.sort
  end

  test "default_plugins is included in to_h" do
    agent_root = AgentRootsConfig.find("agent-orchestrator")
    hash = agent_root.to_h

    assert_includes hash.keys, :default_plugins
    assert_equal [ "ci-workflow", "screenshots-videos" ], hash[:default_plugins].sort
  end

  test "catalog-management no longer has locked-down AO MCP server in default_mcp_servers" do
    agent_root = AgentRootsConfig.find("catalog-management")

    refute_includes agent_root.default_mcp_servers, "agent-orchestrator-server-onboarding",
      "Locked-down AO MCP server should be removed — AO auto-injects from default_subagent_roots"
    refute_includes agent_root.default_mcp_servers, "agent-orchestrator-ai-artifact-engineering",
      "Locked-down AI Artifact Engineering AO MCP server should be removed — AO auto-injects from default_subagent_roots"
  end
end
