# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"
require "ostruct" # OpenStruct builds the mock root below; not autoloaded in isolation

# The create-time defaults chain both spawn surfaces share — POST
# /api/v1/sessions and MCP `start_session`. Tested here once, directly, because
# the whole point of extracting it was that the two surfaces answer these
# questions identically; their own tests then assert that each surface asks.
class Sessions::ResolveSpawnDefaultsTest < ActiveSupport::TestCase
  setup do
    @root = AgentRootsConfig.find!("zimmer")
  end

  test "a root supplies the repository fields and the catalog defaults" do
    session = Session.new(prompt: "x")

    Sessions::ResolveSpawnDefaults.call(session, agent_root_name: "zimmer")

    assert_equal @root.url, session.git_root
    assert_equal @root.default_branch, session.branch
    assert_equal @root.default_mcp_servers || [], session.mcp_servers
    assert_equal "zimmer", session.metadata["agent_root_key"]
    assert_equal @root.default_runtime, session.agent_runtime
    assert session.config["model"].present?
  end

  test "with no root the chain falls through to the Settings-page defaults" do
    AppSetting.delete_all
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.4")
    session = Session.new(git_root: "https://github.com/someone/scratch.git")

    Sessions::ResolveSpawnDefaults.call(session)

    assert_equal "codex", session.agent_runtime
    assert_equal "gpt-5.4", session.config["model"]
    assert_nil session.metadata&.dig("agent_root_key")
    assert_equal "https://github.com/someone/scratch.git", session.git_root
  end

  test "with neither a root nor a Settings-page default the hardcoded defaults stand" do
    AppSetting.delete_all
    session = Session.new(git_root: "https://github.com/someone/scratch.git")

    Sessions::ResolveSpawnDefaults.call(session)

    assert_equal RuntimeRegistry::DEFAULT_RUNTIME, session.agent_runtime
    assert_equal ModelCatalog.default_for(RuntimeRegistry::DEFAULT_RUNTIME), session.config["model"]
  end

  test "an explicit runtime is left exactly as given, so an unregistered one still fails validation" do
    session = Session.new(git_root: "https://github.com/someone/scratch.git", agent_runtime: "not_a_runtime")

    Sessions::ResolveSpawnDefaults.call(session, explicit_runtime: true)

    assert_equal "not_a_runtime", session.agent_runtime
    refute session.valid?
  end

  test "a model that is not valid for the resolved runtime self-heals rather than persisting" do
    AppSetting.delete_all
    AppSetting.create!(default_runtime: "claude_code", default_model: "opus")
    session = Session.new(git_root: "https://github.com/someone/scratch.git", agent_runtime: "codex")

    Sessions::ResolveSpawnDefaults.call(session, explicit_runtime: true)

    assert ModelCatalog.valid_model?("codex", session.config["model"]),
      "#{session.config['model'].inspect} is not a codex model"
  end

  test "an explicit branch is not overwritten by the root's default_branch" do
    session = Session.new(branch: "some-feature")

    Sessions::ResolveSpawnDefaults.call(session, agent_root_name: "zimmer", explicit_branch: true)

    assert_equal "some-feature", session.branch
  end

  test "a git_root already on the session survives the root's url" do
    session = Session.new(git_root: "https://github.com/someone/zimmer-fork.git")

    Sessions::ResolveSpawnDefaults.call(session, agent_root_name: "zimmer")

    assert_equal "https://github.com/someone/zimmer-fork.git", session.git_root
    assert_equal "zimmer", session.metadata["agent_root_key"], "the root's other defaults still apply"
  end

  # Only an OMITTED list falls back to the root's defaults: a caller that asked
  # for no MCP servers must not be handed whatever the root declares.
  test "an explicitly-named list is left alone, empty included" do
    session = Session.new(mcp_servers: [], catalog_skills: [ "open-pr" ])

    Sessions::ResolveSpawnDefaults.call(
      session,
      agent_root_name: "zimmer",
      explicit_lists: { mcp_servers: true, skills: true }
    )

    assert_empty session.mcp_servers
    assert_equal [ "open-pr" ], session.catalog_skills
    assert_equal @root.default_hooks || [], session.catalog_hooks, "an omitted list still takes the root's"
  end

  test "every explicitly-named list is left alone, one branch per artifact" do
    session = Session.new(catalog_hooks: [], catalog_plugins: [])

    Sessions::ResolveSpawnDefaults.call(
      session,
      agent_root_name: "zimmer",
      explicit_lists: { hooks: true, plugins: true }
    )

    assert_empty session.catalog_hooks
    assert_empty session.catalog_plugins
    assert_equal @root.default_mcp_servers || [], session.mcp_servers, "an omitted list still takes the root's"
    assert_equal @root.default_skills || [], session.catalog_skills
  end

  # Stubbed rather than taken from the catalog: no root Zimmer ships declares a
  # subdirectory today, so a test that looked for one would skip itself forever
  # and the branch would go unexercised.
  test "the root's subdirectory fills a blank one and never overwrites a named one" do
    root = OpenStruct.new(
      name: "monorepo-root",
      url: "https://github.com/test/mono.git",
      default_branch: "main",
      subdirectory: "packages/api",
      default_mcp_servers: [],
      default_skills: [],
      default_hooks: [],
      default_plugins: [],
      default_runtime: "claude_code",
      default_model: "opus"
    )
    AgentRootsConfig.stubs(:find!).with("monorepo-root").returns(root)

    from_root = Session.new
    Sessions::ResolveSpawnDefaults.call(from_root, agent_root_name: "monorepo-root")
    assert_equal "packages/api", from_root.subdirectory

    named = Session.new(subdirectory: "somewhere/else")
    Sessions::ResolveSpawnDefaults.call(named, agent_root_name: "monorepo-root")
    assert_equal "somewhere/else", named.subdirectory
  end

  # With no root there are no defaults for an omitted list to fall back to, so
  # omitted IS none — and McpServerBackfill must not undo that at job start.
  test "a rootless spawn's empty mcp_servers is recorded as deliberate" do
    session = Session.new(git_root: AgentRootsConfig.find!("zimmer").url)

    Sessions::ResolveSpawnDefaults.call(session)

    assert_predicate session.mcp_servers, :blank?
    assert session.mcp_servers_explicitly_empty?
  end

  test "a rootless spawn that names servers is not marked as deliberately empty" do
    session = Session.new(git_root: "https://github.com/someone/scratch.git", mcp_servers: [ "context7" ])

    Sessions::ResolveSpawnDefaults.call(session, explicit_lists: { mcp_servers: true })

    assert_equal [ "context7" ], session.mcp_servers
    refute session.mcp_servers_explicitly_empty?
  end

  # A root supplies the defaults an omitted list falls back to, so an empty column
  # under a root is the accidental kind the heal exists for — it must NOT be marked.
  test "a spawn under a root is not marked as deliberately empty" do
    session = Session.new

    Sessions::ResolveSpawnDefaults.call(session, agent_root_name: "zimmer")

    refute session.mcp_servers_explicitly_empty?
  end

  test "an unknown root raises rather than silently spawning rootless" do
    assert_raises(AgentRootsConfig::AgentRootNotFoundError) do
      Sessions::ResolveSpawnDefaults.call(Session.new, agent_root_name: "no-such-root")
    end
  end
end
