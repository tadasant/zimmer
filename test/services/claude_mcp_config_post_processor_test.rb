# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests for ClaudeMcpConfigPostProcessor — the runtime post-processor that
# applies Zimmer-specific tweaks to the `.mcp.json` AIR writes for Claude Code
# sessions. These exercise the processor directly (no AIR CLI / Open3): the
# processor only reads, mutates, and writes the MCP config via the injected
# file system, so there is nothing to shell out to.
class ClaudeMcpConfigPostProcessorTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:active_session)
    @session.update!(
      mcp_servers: [ "playwright-custom" ],
      catalog_skills: [ "zimmer-run-tests" ],
      metadata: { "agent_root_key" => "agent-orchestrator" }
    )
    @working_dir = Dir.mktmpdir
    @mock_fs = MockFileSystemAdapter.new

    # Self-session catalog entry requires AGENT_ORCHESTRATOR_STAGING_API_KEY
    ENV["AGENT_ORCHESTRATOR_STAGING_API_KEY"] = "test-staging-api-key"
  end

  teardown do
    FileUtils.rm_rf(@working_dir) if @working_dir && File.exist?(@working_dir)
    ENV.delete("AGENT_ORCHESTRATOR_STAGING_API_KEY")
  end

  test "post_process! resolves env interpolations" do
    write_config(
      "test-server" => {
        "command" => "node",
        "args" => [ "server.js" ],
        "env" => {
          "API_KEY" => "${TEST_SECRET_KEY}",
          "WITH_DEFAULT" => "${MISSING_VAR:-fallback_value}"
        }
      }
    )

    ENV["TEST_SECRET_KEY"] = "resolved_secret"

    build_processor.post_process!

    result = read_config
    assert_equal "resolved_secret", result.dig("mcpServers", "test-server", "env", "API_KEY")
    assert_equal "fallback_value", result.dig("mcpServers", "test-server", "env", "WITH_DEFAULT")
  ensure
    ENV.delete("TEST_SECRET_KEY")
  end

  test "post_process! injects npx prefix" do
    write_config(
      "test-npx-server" => {
        "command" => "npx",
        "args" => [ "-y", "some-package" ],
        "env" => {}
      }
    )

    build_processor.post_process!

    args = read_config.dig("mcpServers", "test-npx-server", "args")
    assert_includes args, "--prefix"
    assert_includes args, "/tmp"
  end

  test "post_process! injects Zimmer MCP server when root has default_subagent_roots" do
    # Use catalog-management which has default_subagent_roots
    @session.update!(metadata: { "agent_root_key" => "catalog-management" })

    write_config(
      "agent-orchestrator-ai-artifact-engineering" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {}
      }
    )

    processor = build_processor
    processor.post_process!

    result = read_config
    ao_server = result.dig("mcpServers", "agent-orchestrator")
    assert_not_nil ao_server, "agent-orchestrator MCP server should be injected"
    assert_equal "npx", ao_server["command"]
    assert_includes ao_server["args"], "agent-orchestrator-mcp-server@latest"

    allowed = ao_server.dig("env", "ALLOWED_AGENT_ROOTS")
    assert_not_nil allowed
    assert_includes allowed, "catalog-mgmt-research"
    assert_includes allowed, "catalog-mgmt-configs"
    assert_includes allowed, "catalog-mgmt-proctor"
    assert_includes allowed, "catalog-mgmt-save"

    assert_equal [ "agent-orchestrator" ], processor.injected_mcp_servers
  end

  test "post_process! does NOT inject subagent Zimmer server when root has no default_subagent_roots but injects self-session server" do
    # agent-orchestrator root has no default_subagent_roots
    @session.update!(metadata: { "agent_root_key" => "agent-orchestrator" })

    write_config(
      "playwright-custom" => {
        "command" => "npx",
        "args" => [ "-y", "@anthropic/playwright-mcp-server" ],
        "env" => {}
      }
    )

    processor = build_processor
    processor.post_process!

    result = read_config
    assert_nil result.dig("mcpServers", "agent-orchestrator"),
      "subagent agent-orchestrator MCP server should NOT be injected"

    # Self-session server IS injected since no Zimmer server was present
    self_server = result.dig("mcpServers", "agent-orchestrator-staging-self-session")
    assert_not_nil self_server, "self-session Zimmer server should be injected"
    assert_equal "self_session", self_server.dig("env", "TOOL_GROUPS")
    assert_equal [ "agent-orchestrator-staging-self-session" ], processor.injected_mcp_servers
  end

  test "post_process! injects session-scoped Zimmer server with TOOL_GROUPS=self_session" do
    @session.update!(mcp_servers: [ "playwright-custom" ])

    write_config(
      "playwright-custom" => {
        "command" => "npx",
        "args" => [ "-y", "@anthropic/playwright-mcp-server" ],
        "env" => {}
      }
    )

    processor = build_processor
    processor.post_process!

    self_server = read_config.dig("mcpServers", "agent-orchestrator-staging-self-session")
    assert_not_nil self_server, "Self-session Zimmer server should be injected"
    assert_equal "npx", self_server["command"]
    assert_includes self_server["args"], "agent-orchestrator-mcp-server@latest"
    assert_equal "self_session", self_server.dig("env", "TOOL_GROUPS")
    assert_nil self_server.dig("env", "ALLOWED_AGENT_ROOTS"),
      "Self-session server should not restrict agent roots"
  end

  test "post_process! injects self-session server alongside restricted Zimmer server with TOOL_GROUPS" do
    @session.update!(mcp_servers: [ "agent-orchestrator-prod-sessions" ])

    write_config(
      "agent-orchestrator-prod-sessions" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => { "TOOL_GROUPS" => "sessions" }
      }
    )

    processor = build_processor
    processor.post_process!

    result = read_config
    assert_not_nil result.dig("mcpServers", "agent-orchestrator-staging-self-session"),
      "Self-session server SHOULD be injected alongside restricted Zimmer server"
    assert_equal "self_session", result.dig("mcpServers", "agent-orchestrator-staging-self-session", "env", "TOOL_GROUPS")
    assert_equal [ "agent-orchestrator-staging-self-session" ], processor.injected_mcp_servers
  end

  test "post_process! does NOT inject self-session alongside auto-injected subagent Zimmer server (ALLOWED_AGENT_ROOTS set, TOOL_GROUPS blank)" do
    @session.update!(metadata: { "agent_root_key" => "catalog-management" })

    write_config(
      "playwright-custom" => {
        "command" => "npx",
        "args" => [ "-y", "@anthropic/playwright-mcp-server" ],
        "env" => {}
      }
    )

    processor = build_processor
    processor.post_process!

    result = read_config
    assert_not_nil result.dig("mcpServers", "agent-orchestrator"),
      "Subagent Zimmer server should be injected"
    # The subagent Zimmer server has TOOL_GROUPS blank, which means the self_session tool
    # group is already registered. ALLOWED_AGENT_ROOTS does not hide tools at registration
    # time; it only triggers call-time guards on tools that create new sessions/triggers.
    # Injecting a second Zimmer server here causes two concurrent `npx … agent-orchestrator-mcp-server@latest`
    # processes to race on npm's shared `_npx/<hash>` cache directory.
    assert_nil result.dig("mcpServers", "agent-orchestrator-staging-self-session"),
      "Self-session server should NOT be injected when subagent Zimmer server already covers self_session tools"
    assert_equal [ "agent-orchestrator" ], processor.injected_mcp_servers
  end

  test "post_process! synthesizes a baseline .mcp.json with the self-session server when AIR wrote no file" do
    # A skills-only session (no explicit MCP servers) takes the prepare! branch
    # but AIR writes no .mcp.json. post_process! must still create one and inject
    # the self-session server rather than leaving the session with no Zimmer tools.
    @session.update!(mcp_servers: [], catalog_skills: [ "zimmer-run-tests" ], metadata: { "agent_root_key" => "agent-orchestrator" })

    processor = build_processor
    processor.post_process!

    assert @mock_fs.exists?(File.join(@working_dir, ".mcp.json")),
      "post_process! should synthesize a .mcp.json when AIR wrote none"
    self_server = read_config.dig("mcpServers", "agent-orchestrator-staging-self-session")
    assert_not_nil self_server, "Self-session Zimmer server should be injected into the synthesized config"
    assert_equal "self_session", self_server.dig("env", "TOOL_GROUPS")
    assert_equal [ "agent-orchestrator-staging-self-session" ], processor.injected_mcp_servers
  end

  test "post_process! injects the subagent Zimmer server when AIR wrote no .mcp.json for a subagent-roots root" do
    # The secondary defect: a subagent-roots root that has skills (so it takes
    # the prepare! branch) but no explicit MCP servers gets no .mcp.json from AIR.
    # post_process! must still inject the subagent-spawning agent-orchestrator
    # server so start_session works — it must not be gated on an AIR-produced file.
    @session.update!(
      mcp_servers: [],
      catalog_skills: [ "zimmer-run-tests" ],
      metadata: { "agent_root_key" => "catalog-management" }
    )

    processor = build_processor
    processor.post_process!

    assert @mock_fs.exists?(File.join(@working_dir, ".mcp.json")),
      "post_process! should synthesize a .mcp.json when AIR wrote none"
    result = read_config
    ao_server = result.dig("mcpServers", "agent-orchestrator")
    assert_not_nil ao_server,
      "subagent-spawning agent-orchestrator server must be injected even without an AIR-produced .mcp.json"
    allowed = ao_server.dig("env", "ALLOWED_AGENT_ROOTS")
    assert_includes allowed, "catalog-mgmt-research"
    assert_includes allowed, "catalog-mgmt-save"

    # The full-surface subagent server already covers the self_session tool group,
    # so the dedicated self-session server is deduped away (no duplicate Zimmer server).
    assert_nil result.dig("mcpServers", "agent-orchestrator-staging-self-session"),
      "Self-session server should be deduped when the subagent Zimmer server is present"
    assert_equal [ "agent-orchestrator" ], processor.injected_mcp_servers
  end

  # ---------------------------------------------------------------------------
  # ensure_baseline!
  # ---------------------------------------------------------------------------

  test "ensure_baseline! creates .mcp.json with self-session server when no file exists" do
    @session.update!(mcp_servers: [], catalog_skills: [])

    processor = build_processor
    processor.ensure_baseline!

    config_path = File.join(@working_dir, ".mcp.json")
    assert @mock_fs.exists?(config_path), ".mcp.json should be created"

    self_server = read_config.dig("mcpServers", "agent-orchestrator-staging-self-session")
    assert_not_nil self_server, "Self-session Zimmer server should be injected"
    assert_equal "self_session", self_server.dig("env", "TOOL_GROUPS")
    assert_equal [ "agent-orchestrator-staging-self-session" ], processor.injected_mcp_servers
  end

  test "ensure_baseline! applies npx prefix to injected server" do
    @session.update!(mcp_servers: [], catalog_skills: [])

    build_processor.ensure_baseline!

    args = read_config.dig("mcpServers", "agent-orchestrator-staging-self-session", "args")
    assert_includes args, "--prefix"
    assert_includes args, "/tmp"
  end

  test "ensure_baseline! injects into pre-existing .mcp.json without Zimmer server" do
    @session.update!(mcp_servers: [], catalog_skills: [])

    write_config(
      "some-other-server" => {
        "command" => "node",
        "args" => [ "server.js" ],
        "env" => {}
      }
    )

    processor = build_processor
    processor.ensure_baseline!

    result = read_config
    assert_equal 2, result["mcpServers"].keys.length,
      "Should have both existing and injected servers"
    assert_not_nil result.dig("mcpServers", "some-other-server"),
      "Pre-existing server should be preserved"
    assert_not_nil result.dig("mcpServers", "agent-orchestrator-staging-self-session"),
      "Self-session server should be injected"
    assert_equal [ "agent-orchestrator-staging-self-session" ], processor.injected_mcp_servers
  end

  test "ensure_baseline! does NOT inject alongside subagent-restricted Zimmer server (ALLOWED_AGENT_ROOTS set, TOOL_GROUPS blank)" do
    @session.update!(mcp_servers: [], catalog_skills: [])

    write_config(
      "agent-orchestrator" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {
          "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
          "AGENT_ORCHESTRATOR_API_KEY" => "test-key",
          "ALLOWED_AGENT_ROOTS" => "some-root"
        }
      }
    )

    processor = build_processor
    processor.ensure_baseline!

    result = read_config
    # An Zimmer server with TOOL_GROUPS blank already registers the full self_session tool
    # group, so the self-session server is redundant.
    assert_nil result.dig("mcpServers", "agent-orchestrator-staging-self-session"),
      "Self-session server should NOT be injected when a Zimmer server with TOOL_GROUPS blank is already present"
    assert_empty processor.injected_mcp_servers
  end

  test "ensure_baseline! skips when Zimmer server with TOOL_GROUPS blank is already present" do
    @session.update!(mcp_servers: [], catalog_skills: [])

    write_config(
      "agent-orchestrator" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {
          "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
          "AGENT_ORCHESTRATOR_API_KEY" => "test-key"
        }
      }
    )

    processor = build_processor
    processor.ensure_baseline!

    assert_nil read_config.dig("mcpServers", "agent-orchestrator-staging-self-session"),
      "Self-session server should NOT be injected when a Zimmer server with TOOL_GROUPS blank is present"
    assert_empty processor.injected_mcp_servers
  end

  test "ensure_baseline! injects alongside restricted Zimmer server in .mcp.json" do
    @session.update!(mcp_servers: [], catalog_skills: [])

    write_config(
      "agent-orchestrator-prod-sessions" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {
          "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
          "AGENT_ORCHESTRATOR_API_KEY" => "test-key",
          "TOOL_GROUPS" => "sessions"
        }
      }
    )

    processor = build_processor
    processor.ensure_baseline!

    result = read_config
    assert_not_nil result.dig("mcpServers", "agent-orchestrator-prod-sessions"),
      "Existing restricted Zimmer server should be preserved"
    assert_not_nil result.dig("mcpServers", "agent-orchestrator-staging-self-session"),
      "Self-session server SHOULD be injected alongside restricted Zimmer server"
    assert_equal "self_session", result.dig("mcpServers", "agent-orchestrator-staging-self-session", "env", "TOOL_GROUPS")
    assert_equal [ "agent-orchestrator-staging-self-session" ], processor.injected_mcp_servers
  end

  test "ensure_baseline! injects the subagent Zimmer server for a subagent-roots-only root" do
    # catalog-management has NO default_mcp_servers/skills/hooks/plugins, so
    # its regeneration routes through the baseline path. Its only subagent-spawning
    # capability is the auto-injected agent-orchestrator server. ensure_baseline!
    # must inject it (with the resolved default_subagent_roots as ALLOWED_AGENT_ROOTS)
    # or the session loses start_session entirely. This is the primary defect.
    @session.update!(
      mcp_servers: [],
      catalog_skills: [],
      catalog_hooks: [],
      catalog_plugins: [],
      metadata: { "agent_root_key" => "catalog-management" }
    )

    processor = build_processor
    processor.ensure_baseline!

    result = read_config
    ao_server = result.dig("mcpServers", "agent-orchestrator")
    assert_not_nil ao_server,
      "ensure_baseline! must inject the subagent-spawning agent-orchestrator server for a subagent-roots root"
    assert_equal "npx", ao_server["command"]
    assert_includes ao_server["args"], "agent-orchestrator-mcp-server@latest"

    allowed = ao_server.dig("env", "ALLOWED_AGENT_ROOTS")
    assert_includes allowed, "catalog-mgmt-research"
    assert_includes allowed, "catalog-mgmt-configs"
    assert_includes allowed, "catalog-mgmt-proctor"
    assert_includes allowed, "catalog-mgmt-save"

    # The subagent server (TOOL_GROUPS blank) already covers the self_session tool
    # group, so the dedicated self-session server is deduped away.
    assert_nil result.dig("mcpServers", "agent-orchestrator-staging-self-session"),
      "Self-session server should be deduped when the subagent Zimmer server is present"
    assert_equal [ "agent-orchestrator" ], processor.injected_mcp_servers
  end

  test "ensure_baseline! does NOT inject the subagent Zimmer server for a root without default_subagent_roots" do
    # agent-orchestrator root has no default_subagent_roots: only the self-session
    # server should be injected, never the subagent-spawning server.
    @session.update!(mcp_servers: [], catalog_skills: [], metadata: { "agent_root_key" => "agent-orchestrator" })

    processor = build_processor
    processor.ensure_baseline!

    result = read_config
    assert_nil result.dig("mcpServers", "agent-orchestrator"),
      "subagent agent-orchestrator server must NOT be injected for a root without default_subagent_roots"
    assert_not_nil result.dig("mcpServers", "agent-orchestrator-staging-self-session"),
      "Self-session server should still be injected"
    assert_equal [ "agent-orchestrator-staging-self-session" ], processor.injected_mcp_servers
  end

  # ---------------------------------------------------------------------------
  # Env-aware retargeting of agent-orchestrator-* MCP server entries
  # ---------------------------------------------------------------------------
  # Fundamental problem these tests guard against: roots.json declares
  # `agent-orchestrator-prod` in default_mcp_servers for several roots
  # (ao-router, ao-heartbeat, etc.). When AIR resolves the catalog, those
  # entries default to https://zimmer.example.com. A local-dev or staging session
  # inheriting that default would orchestrate PRODUCTION Zimmer instead of its own
  # instance. The post-processor rewrites BASE_URL/API_KEY at .mcp.json-write
  # time so the catalog stays env-agnostic.

  test "post_process! retargets agent-orchestrator-prod entry to local in dev env" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-test-key"

    write_config(
      "agent-orchestrator-prod" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {
          "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
          "AGENT_ORCHESTRATOR_API_KEY" => "prod-key-should-be-replaced"
        }
      }
    )

    build_processor.post_process!

    prod_server = read_config.dig("mcpServers", "agent-orchestrator-prod")
    assert_equal "http://localhost:3000", prod_server.dig("env", "AGENT_ORCHESTRATOR_BASE_URL"),
      "agent-orchestrator-prod BASE_URL should be retargeted to localhost in test/dev env " \
      "so the session orchestrates the local Zimmer instance, not production"
    assert_equal "local-test-key", prod_server.dig("env", "AGENT_ORCHESTRATOR_API_KEY"),
      "agent-orchestrator-prod API_KEY should be retargeted to local key in test/dev env"
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
  end

  test "post_process! retargets all agent-orchestrator-* entries" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-test-key"

    write_config(
      "agent-orchestrator-prod" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {
          "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
          "AGENT_ORCHESTRATOR_API_KEY" => "prod-key"
        }
      },
      "agent-orchestrator-prod-sessions" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {
          "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
          "AGENT_ORCHESTRATOR_API_KEY" => "prod-key",
          "TOOL_GROUPS" => "sessions",
          "ALLOWED_AGENT_ROOTS" => "some-root"
        }
      }
    )

    build_processor.post_process!
    result = read_config

    prod = result.dig("mcpServers", "agent-orchestrator-prod")
    assert_equal "http://localhost:3000", prod.dig("env", "AGENT_ORCHESTRATOR_BASE_URL")
    assert_equal "local-test-key", prod.dig("env", "AGENT_ORCHESTRATOR_API_KEY")

    sessions_entry = result.dig("mcpServers", "agent-orchestrator-prod-sessions")
    assert_equal "http://localhost:3000", sessions_entry.dig("env", "AGENT_ORCHESTRATOR_BASE_URL")
    assert_equal "local-test-key", sessions_entry.dig("env", "AGENT_ORCHESTRATOR_API_KEY")
    assert_equal "sessions", sessions_entry.dig("env", "TOOL_GROUPS"),
      "Retarget should NOT clobber non-URL/non-KEY env vars like TOOL_GROUPS"
    assert_equal "some-root", sessions_entry.dig("env", "ALLOWED_AGENT_ROOTS"),
      "Retarget should NOT clobber non-URL/non-KEY env vars like ALLOWED_AGENT_ROOTS"
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
  end

  test "post_process! does NOT retarget non-agent-orchestrator entries" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-test-key"

    write_config(
      "playwright-custom" => {
        "command" => "npx",
        "args" => [ "-y", "@anthropic/playwright-mcp-server" ],
        "env" => {
          "SOMETHING_BASE_URL" => "https://example.com",
          "SOMETHING_API_KEY" => "do-not-touch"
        }
      }
    )

    build_processor.post_process!

    pw = read_config.dig("mcpServers", "playwright-custom")
    assert_equal "https://example.com", pw.dig("env", "SOMETHING_BASE_URL"),
      "Non-Zimmer servers must not be touched by retargeting"
    assert_equal "do-not-touch", pw.dig("env", "SOMETHING_API_KEY"),
      "Non-Zimmer servers must not be touched by retargeting"
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
  end

  test "post_process! does NOT retarget in production env" do
    # Rails.env is a framework primitive (not internal application code), and there
    # is no clean dependency-injection seam for it on a class method. Stubbing it
    # here is the simplest way to exercise the env-conditional branch.
    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      write_config(
        "agent-orchestrator-prod" => {
          "command" => "npx",
          "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
          "env" => {
            "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
            "AGENT_ORCHESTRATOR_API_KEY" => "real-prod-key"
          }
        }
      )

      build_processor.post_process!

      prod = read_config.dig("mcpServers", "agent-orchestrator-prod")
      assert_equal "https://zimmer.example.com", prod.dig("env", "AGENT_ORCHESTRATOR_BASE_URL"),
        "In production env, agent-orchestrator-prod BASE_URL must be pass-through " \
        "(the catalog already points at the right place)"
      assert_equal "real-prod-key", prod.dig("env", "AGENT_ORCHESTRATOR_API_KEY"),
        "In production env, agent-orchestrator-prod API_KEY must be pass-through"
    end
  end

  test "post_process! retargets agent-orchestrator-prod to staging URL in staging env" do
    ENV["AGENT_ORCHESTRATOR_STAGING_BASE_URL"] = "https://staging.zimmer.example.com"
    # AGENT_ORCHESTRATOR_STAGING_API_KEY is set in test setup

    Rails.stub(:env, ActiveSupport::StringInquirer.new("staging")) do
      write_config(
        "agent-orchestrator-prod" => {
          "command" => "npx",
          "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
          "env" => {
            "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
            "AGENT_ORCHESTRATOR_API_KEY" => "prod-key-not-staging"
          }
        }
      )

      build_processor.post_process!

      prod = read_config.dig("mcpServers", "agent-orchestrator-prod")
      assert_equal "https://staging.zimmer.example.com", prod.dig("env", "AGENT_ORCHESTRATOR_BASE_URL"),
        "In staging env, agent-orchestrator-prod BASE_URL should be retargeted to staging"
      assert_equal "test-staging-api-key", prod.dig("env", "AGENT_ORCHESTRATOR_API_KEY"),
        "In staging env, agent-orchestrator-prod API_KEY should be the staging key"
    end
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_STAGING_BASE_URL")
  end

  test "inject_subagent_ao_server! uses local target in dev env" do
    # When a parent root with default_subagent_roots spawns subagents, the
    # auto-injected agent-orchestrator MCP server must point at the LOCAL Zimmer
    # instance in dev, not production.
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-test-key"
    @session.update!(metadata: { "agent_root_key" => "catalog-management" })

    write_config("noop" => { "command" => "true", "args" => [], "env" => {} })

    build_processor.post_process!

    injected = read_config.dig("mcpServers", "agent-orchestrator")
    assert_not_nil injected, "Subagent Zimmer server should be injected for catalog-management"
    assert_equal "http://localhost:3000", injected.dig("env", "AGENT_ORCHESTRATOR_BASE_URL"),
      "Auto-injected subagent Zimmer server BASE_URL must be the local instance, not prod"
    assert_equal "local-test-key", injected.dig("env", "AGENT_ORCHESTRATOR_API_KEY"),
      "Auto-injected subagent Zimmer server API_KEY must be the local key, not prod"
    assert_not_nil injected.dig("env", "ALLOWED_AGENT_ROOTS"),
      "Auto-injected subagent Zimmer server must keep ALLOWED_AGENT_ROOTS"
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
  end

  test "inject_subagent_ao_server! uses prod target in production env" do
    ENV["AGENT_ORCHESTRATOR_PROD_API_KEY"] = "real-prod-key"
    @session.update!(metadata: { "agent_root_key" => "catalog-management" })

    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      write_config("noop" => { "command" => "true", "args" => [], "env" => {} })

      build_processor.post_process!

      injected = read_config.dig("mcpServers", "agent-orchestrator")
      assert_not_nil injected
      assert_equal "https://zimmer.example.com", injected.dig("env", "AGENT_ORCHESTRATOR_BASE_URL")
      assert_equal "real-prod-key", injected.dig("env", "AGENT_ORCHESTRATOR_API_KEY")
    end
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_PROD_API_KEY")
  end

  test "retarget honors AGENT_ORCHESTRATOR_LOCAL_BASE_URL override" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_BASE_URL"] = "http://localhost:9999"
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-test-key"

    write_config(
      "agent-orchestrator-prod" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {
          "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
          "AGENT_ORCHESTRATOR_API_KEY" => "prod-key"
        }
      }
    )

    build_processor.post_process!

    prod = read_config.dig("mcpServers", "agent-orchestrator-prod")
    assert_equal "http://localhost:9999", prod.dig("env", "AGENT_ORCHESTRATOR_BASE_URL"),
      "When AGENT_ORCHESTRATOR_LOCAL_BASE_URL is set, retarget should use that exact value"
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_BASE_URL")
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
  end

  test "ensure_baseline! inject_self_session + retarget produces localhost-targeted self-session in dev env" do
    # Reproduce the bug class the user reported: Zimmer running locally, but the
    # auto-injected self-session MCP server points at staging URL and gets a 401.
    # The catalog only defines staging/prod self-session entries, so in dev,
    # the self-session injector falls back to the staging catalog entry.
    # Retarget must then rewrite BASE_URL/API_KEY to the local instance.
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-test-key"
    @session.update!(mcp_servers: [])  # no user-selected Zimmer server → self-session injection fires

    write_config({})

    build_processor.ensure_baseline!

    self_session = read_config.dig("mcpServers", "agent-orchestrator-staging-self-session")
    assert_not_nil self_session,
      "ensure_baseline! should inject the staging-flavored self-session entry in dev"
    assert_equal "http://localhost:3000", self_session.dig("env", "AGENT_ORCHESTRATOR_BASE_URL"),
      "Self-session BASE_URL must be retargeted to localhost in dev, not staging.zimmer.example.com"
    assert_equal "local-test-key", self_session.dig("env", "AGENT_ORCHESTRATOR_API_KEY"),
      "Self-session API_KEY must be retargeted to the local key in dev, not the staging key"
    assert_equal "self_session", self_session.dig("env", "TOOL_GROUPS"),
      "Retarget must preserve TOOL_GROUPS=self_session on the self-session entry"
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
  end

  test "post_process! logs warning when retargeting with blank API key" do
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")

    write_config(
      "agent-orchestrator-prod" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {
          "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
          "AGENT_ORCHESTRATOR_API_KEY" => "prod-key"
        }
      }
    )

    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    build_processor.post_process!

    assert_match(/Retargeted agent-orchestrator-\* servers.*blank API_KEY/,
      log_output.string,
      "Expected warning when API_KEY is blank after retarget")
    assert_match(/AGENT_ORCHESTRATOR_LOCAL_API_KEY/,
      log_output.string,
      "Warning should name the env var the dev needs to set")
  ensure
    Rails.logger = original_logger if original_logger
  end

  test "post_process! does NOT warn when retargeted API key is present" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-test-key"

    write_config(
      "agent-orchestrator-prod" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => { "AGENT_ORCHESTRATOR_API_KEY" => "prod-key" }
      }
    )

    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    build_processor.post_process!

    refute_match(/blank API_KEY/, log_output.string,
      "Should not warn when API key is present after retarget")
  ensure
    Rails.logger = original_logger if original_logger
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
  end

  # ---------------------------------------------------------------------------
  # Golden file — byte-for-byte stability of the written .mcp.json
  # ---------------------------------------------------------------------------
  # Locks in the exact serialized output for a representative config so the
  # Phase-1 extraction (and any future change to the post-processor) cannot
  # silently alter the bytes Zimmer writes. The input deliberately includes a Zimmer
  # server with TOOL_GROUPS blank so self-session injection is deduped away —
  # this keeps the output independent of the runtime catalog and fully
  # deterministic.
  test "post_process! produces byte-for-byte stable .mcp.json (golden file)" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-key"

    write_config(
      "agent-orchestrator-prod" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {
          "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
          "AGENT_ORCHESTRATOR_API_KEY" => "prod-key"
        }
      },
      "some-npx-server" => {
        "command" => "npx",
        "args" => [ "-y", "some-package" ],
        "env" => { "TOKEN" => "${GOLDEN_FILE_UNSET_VAR:-fallback}" }
      }
    )

    build_processor.post_process!

    expected = {
      "mcpServers" => {
        "agent-orchestrator-prod" => {
          "command" => "npx",
          "args" => [ "-y", "--prefix", "/tmp", "agent-orchestrator-mcp-server@latest" ],
          "env" => {
            "AGENT_ORCHESTRATOR_BASE_URL" => "http://localhost:3000",
            "AGENT_ORCHESTRATOR_API_KEY" => "local-key"
          }
        },
        "some-npx-server" => {
          "command" => "npx",
          "args" => [ "-y", "--prefix", "/tmp", "some-package" ],
          "env" => { "TOKEN" => "fallback" }
        }
      }
    }

    assert_equal JSON.pretty_generate(expected),
      @mock_fs.read(File.join(@working_dir, ".mcp.json")),
      "Written .mcp.json must match the golden serialization byte-for-byte"
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
  end

  private

  def build_processor
    ClaudeMcpConfigPostProcessor.new(
      session: @session,
      working_directory: @working_dir,
      file_system: @mock_fs
    )
  end

  def write_config(servers)
    @mock_fs.write(
      File.join(@working_dir, ".mcp.json"),
      JSON.pretty_generate("mcpServers" => servers)
    )
  end

  def read_config
    JSON.parse(@mock_fs.read(File.join(@working_dir, ".mcp.json")))
  end
end
