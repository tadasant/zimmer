# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests for ClaudeMcpConfigPostProcessor — the runtime post-processor that
# applies Zimmer-specific tweaks to the `.mcp.json` AIR writes for Claude Code
# sessions. These exercise the processor directly (no AIR CLI / Open3): the
# processor only reads, mutates, and writes the MCP config via the injected
# file system, so there is nothing to shell out to.
#
# Zimmer serves MCP natively, so the servers it auto-injects are streamable-HTTP
# entries pointing back at this instance's own /mcp endpoint, scoped by query
# string:
#
#   zimmer-self-session : /mcp?tool_groups=self_session   (every session)
#   zimmer              : /mcp?allowed_agent_roots=<...>  (roots with subagents)
#
# In Claude's `.mcp.json` that is `{"type": "http", "url": …, "headers": {…}}`.
class ClaudeMcpConfigPostProcessorTest < ActiveSupport::TestCase
  SELF_SESSION_SERVER = "zimmer-self-session"
  SUBAGENT_SERVER = "zimmer"
  SUBAGENT_ROOTS = %w[catalog-mgmt-research catalog-mgmt-configs catalog-mgmt-proctor catalog-mgmt-save].freeze

  # Env vars the instance-resolution logic reads. Saved and restored around each
  # test so an ambient .env value can never make an assertion pass (or fail) by
  # accident, and so a test that deletes one does not leak that deletion.
  MANAGED_ENV_VARS = %w[
    ZIMMER_LOCAL_BASE_URL
    ZIMMER_LOCAL_API_KEY
    ZIMMER_STAGING_BASE_URL
    ZIMMER_STAGING_API_KEY
    ZIMMER_PROD_BASE_URL
    ZIMMER_PROD_API_KEY
  ].freeze

  setup do
    @session = sessions(:active_session)
    @session.update!(
      mcp_servers: [ "playwright-custom" ],
      catalog_skills: [ "zimmer-run-tests" ],
      metadata: { "agent_root_key" => "agent-orchestrator" }
    )
    @working_dir = Dir.mktmpdir
    @mock_fs = MockFileSystemAdapter.new

    @original_env = ENV.to_hash.slice(*MANAGED_ENV_VARS)
    MANAGED_ENV_VARS.each { |var| ENV.delete(var) }
    # Tests run with Rails.env == "test", which resolves to the LOCAL instance.
    ENV["ZIMMER_LOCAL_API_KEY"] = "local-test-key"
  end

  teardown do
    FileUtils.rm_rf(@working_dir) if @working_dir && File.exist?(@working_dir)
    MANAGED_ENV_VARS.each { |var| ENV.delete(var) }
    @original_env.each { |var, value| ENV[var] = value }
  end

  # ---------------------------------------------------------------------------
  # Secret resolution + npx rewrite (format-agnostic value logic)
  # ---------------------------------------------------------------------------

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

  test "post_process! resolves header interpolations on http entries" do
    write_config(
      "acme-http" => {
        "type" => "http",
        "url" => "https://acme.example.com/mcp",
        "headers" => { "Authorization" => "${TEST_HEADER_TOKEN}" }
      }
    )

    ENV["TEST_HEADER_TOKEN"] = "tok-123"

    build_processor.post_process!

    assert_equal "tok-123", read_config.dig("mcpServers", "acme-http", "headers", "Authorization")
  ensure
    ENV.delete("TEST_HEADER_TOKEN")
  end

  # Regression guard for zimmer#467: Zimmer used to splice `--prefix /tmp` into
  # every npx invocation here. That aimed npm's bin-linking at a directory that
  # does not exist on the host, so the `chmod 0755` that accompanies bin-linking
  # never landed and the server died on `exec` with EACCES on every retry —
  # terminally orphaning production session 4388 three times in 31 minutes. It
  # also pointed npm at a host-shared path, defeating the per-clone
  # NPM_CONFIG_CACHE isolation. A catalog entry's argv must reach `.mcp.json`
  # exactly as the catalog wrote it.
  test "post_process! writes an npx server's command and args through verbatim" do
    write_config(
      "test-npx-server" => {
        "command" => "npx",
        "args" => [ "-y", "some-package" ],
        "env" => {}
      }
    )

    build_processor.post_process!

    entry = read_config.dig("mcpServers", "test-npx-server")
    assert_equal "npx", entry["command"]
    assert_equal [ "-y", "some-package" ], entry["args"]
  end

  # ---------------------------------------------------------------------------
  # The elicitation address → each stdio server's own env
  # ---------------------------------------------------------------------------
  # Claude Code hands a stdio MCP server the agent process's environment, so these
  # variables already arrived via CliSpawnEnv. Writing them into the config too is
  # what makes the two runtimes agree — and what stops a stale catalog `env` from
  # shadowing the injected URL, which is the half of the bug that was never
  # runtime-specific. These tests exist to prove the Claude path did not regress.

  test "post_process! writes the elicitation address into a stdio server's env" do
    write_config(
      "test-server" => { "command" => "node", "args" => [ "server.js" ] },
      "acme-http" => { "type" => "http", "url" => "https://acme.example.com/mcp" }
    )

    build_processor.post_process!

    result = read_config
    assert_equal ElicitationEndpoint.url, result.dig("mcpServers", "test-server", "env", "ELICITATION_REQUEST_URL")
    assert_equal @session.id.to_s, result.dig("mcpServers", "test-server", "env", "ELICITATION_SESSION_ID")
    assert_nil result.dig("mcpServers", "acme-http", "env"),
      "an HTTP entry has no child process, so it gets no env"
  end

  test "post_process! merges the elicitation address into an existing env, leaving its entries intact" do
    write_config(
      "test-server" => {
        "command" => "node",
        "args" => [ "server.js" ],
        "env" => { "API_KEY" => "sk-literal-123", "REGION" => "us-east-1" }
      }
    )

    build_processor.post_process!

    env = read_config.dig("mcpServers", "test-server", "env")
    assert_equal "sk-literal-123", env["API_KEY"],
      "the env table holds the server's credentials — injection must merge, never replace"
    assert_equal "us-east-1", env["REGION"]
    assert_equal ElicitationEndpoint.url, env["ELICITATION_REQUEST_URL"]
  end

  test "post_process! overrides a catalog entry's own stale elicitation URL" do
    write_config(
      "test-server" => {
        "command" => "node",
        "args" => [ "server.js" ],
        "env" => { "ELICITATION_REQUEST_URL" => "http://zimmer/api/v1/elicitations" }
      }
    )

    build_processor.post_process!

    assert_equal ElicitationEndpoint.url,
      read_config.dig("mcpServers", "test-server", "env", "ELICITATION_REQUEST_URL"),
      "Zimmer's address for its own endpoint wins over a catalog copy that can go stale"
  end

  test "post_process! prefers an elicitation URL the clone's .env sets" do
    @mock_fs.write(File.join(@working_dir, ".env"), <<~ENV)
      ELICITATION_REQUEST_URL="https://other-zimmer.example.com/api/v1/elicitations"
    ENV

    write_config("test-server" => { "command" => "node", "args" => [ "server.js" ] })

    build_processor.post_process!

    env = read_config.dig("mcpServers", "test-server", "env")
    assert_equal "https://other-zimmer.example.com/api/v1/elicitations", env["ELICITATION_REQUEST_URL"],
      "the .env escape hatch must govern the server's env exactly as it governs the agent process"
    assert_equal @session.id.to_s, env["ELICITATION_SESSION_ID"]
  end

  # ---------------------------------------------------------------------------
  # Injection: the subagent server (roots with default_subagent_roots)
  # ---------------------------------------------------------------------------

  test "post_process! injects the full-surface zimmer server when root has default_subagent_roots" do
    # catalog-management is the root with default_subagent_roots.
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

    zimmer = read_config.dig("mcpServers", SUBAGENT_SERVER)
    assert_not_nil zimmer, "zimmer MCP server should be injected"
    assert_equal "http", zimmer["type"], "Claude needs an explicit transport type on an http entry"
    assert_nil zimmer["command"], "The native MCP entry is HTTP, not an npx stdio process"

    params = query_params(zimmer["url"])
    assert_equal "http://localhost:3000/mcp", url_without_query(zimmer["url"]),
      "Injected server must point at this instance's own /mcp endpoint"
    assert_nil params["tool_groups"],
      "The subagent server is full-surface — scoping it by tool group would strip start_session"
    assert_equal SUBAGENT_ROOTS.sort, params["allowed_agent_roots"].split(",").sort

    assert_equal({ "X-API-Key" => "local-test-key" }, zimmer["headers"])
    assert_equal [ SUBAGENT_SERVER ], processor.injected_mcp_servers
  end

  test "post_process! does NOT inject the subagent server when root has no default_subagent_roots but injects self-session server" do
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
    assert_nil result.dig("mcpServers", SUBAGENT_SERVER),
      "subagent zimmer MCP server should NOT be injected"

    # Self-session server IS injected since no Zimmer server was present
    self_server = result.dig("mcpServers", SELF_SESSION_SERVER)
    assert_not_nil self_server, "self-session Zimmer server should be injected"
    assert_equal self_session_url, self_server["url"]
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  test "post_process! does NOT overwrite a catalog-provided unrestricted zimmer entry for a subagent-roots root" do
    # A root with default_subagent_roots whose catalog ALSO ships an unrestricted,
    # full-surface `zimmer` entry. In the native MCP world every Zimmer variant is
    # the same URL differentiated only by query param, so blindly writing
    # servers["zimmer"] would clobber the catalog entry with our root-restricted
    # one — silently narrowing start_session's allowed_agent_roots. The catalog
    # entry must survive untouched (retargeting aside), so start_session keeps its
    # full root surface.
    @session.update!(metadata: { "agent_root_key" => "catalog-management" })

    write_config(
      SUBAGENT_SERVER => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp",
        "headers" => { "X-API-Key" => "prod-key" }
      }
    )

    processor = build_processor
    processor.post_process!

    zimmer = read_config.dig("mcpServers", SUBAGENT_SERVER)
    assert_not_nil zimmer, "The catalog-provided zimmer entry must survive"
    assert_nil query_params(zimmer["url"])["allowed_agent_roots"],
      "The catalog's unrestricted entry must NOT be narrowed to the root's subagent list — " \
      "start_session must still accept roots outside that list"
    assert_equal "http://localhost:3000/mcp", url_without_query(zimmer["url"]),
      "The surviving catalog entry is still retargeted at the local instance"
    assert_empty processor.injected_mcp_servers,
      "Nothing is injected when a catalog zimmer entry already covers the surface"
  end

  test "post_process! still injects the subagent server when NO catalog zimmer entry is present" do
    # The dedup guard must not suppress the injection in the normal case: a
    # subagent-roots root whose catalog does not ship a `zimmer` entry still needs
    # the root-restricted server injected so it can spawn its declared subagents.
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

    zimmer = read_config.dig("mcpServers", SUBAGENT_SERVER)
    assert_not_nil zimmer, "The subagent server must still be injected without a catalog zimmer entry"
    assert_equal SUBAGENT_ROOTS.sort,
      query_params(zimmer["url"])["allowed_agent_roots"].split(",").sort
    assert_equal [ SUBAGENT_SERVER ], processor.injected_mcp_servers
  end

  # ---------------------------------------------------------------------------
  # Injection: the self-session server
  # ---------------------------------------------------------------------------

  test "post_process! injects the self-session server scoped to tool_groups=self_session" do
    @session.update!(mcp_servers: [ "playwright-custom" ])

    write_config(
      "playwright-custom" => {
        "command" => "npx",
        "args" => [ "-y", "@anthropic/playwright-mcp-server" ],
        "env" => {}
      }
    )

    build_processor.post_process!

    self_server = read_config.dig("mcpServers", SELF_SESSION_SERVER)
    assert_not_nil self_server, "Self-session Zimmer server should be injected"
    assert_equal "http", self_server["type"]
    assert_equal self_session_url, self_server["url"]
    assert_equal({ "X-API-Key" => "local-test-key" }, self_server["headers"])

    params = query_params(self_server["url"])
    assert_equal "self_session", params["tool_groups"]
    assert_nil params["allowed_agent_roots"],
      "Self-session server should not restrict agent roots"
  end

  test "post_process! injects self-session server alongside a scoped zimmer-sessions server" do
    # A Zimmer entry scoped to other tool groups does NOT cover self_session, so
    # the self-session server is still needed.
    write_config(
      "zimmer-sessions" => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp?tool_groups=sessions",
        "headers" => { "X-API-Key" => "prod-key" }
      }
    )

    processor = build_processor
    processor.post_process!

    result = read_config
    self_server = result.dig("mcpServers", SELF_SESSION_SERVER)
    assert_not_nil self_server,
      "Self-session server SHOULD be injected alongside a Zimmer server scoped to other tool groups"
    assert_equal "self_session", query_params(self_server["url"])["tool_groups"]
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  test "post_process! does NOT inject self-session alongside the auto-injected full-surface zimmer server" do
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
    assert_not_nil result.dig("mcpServers", SUBAGENT_SERVER),
      "Subagent Zimmer server should be injected"
    # The subagent Zimmer entry carries no tool_groups, so it already exposes the
    # full surface — including every self_session tool. A second Zimmer entry
    # would be pure duplication (two MCP connections to the same endpoint).
    assert_nil result.dig("mcpServers", SELF_SESSION_SERVER),
      "Self-session server should NOT be injected when the full-surface zimmer server already covers it"
    assert_equal [ SUBAGENT_SERVER ], processor.injected_mcp_servers
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
    self_server = read_config.dig("mcpServers", SELF_SESSION_SERVER)
    assert_not_nil self_server, "Self-session Zimmer server should be injected into the synthesized config"
    assert_equal self_session_url, self_server["url"]
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  test "post_process! injects the subagent Zimmer server when AIR wrote no .mcp.json for a subagent-roots root" do
    # The secondary defect: a subagent-roots root that has skills (so it takes
    # the prepare! branch) but no explicit MCP servers gets no .mcp.json from AIR.
    # post_process! must still inject the subagent-spawning zimmer server so
    # start_session works — it must not be gated on an AIR-produced file.
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
    zimmer = result.dig("mcpServers", SUBAGENT_SERVER)
    assert_not_nil zimmer,
      "subagent-spawning zimmer server must be injected even without an AIR-produced .mcp.json"
    allowed = query_params(zimmer["url"])["allowed_agent_roots"].to_s.split(",")
    assert_equal SUBAGENT_ROOTS.sort, allowed.sort

    # The full-surface subagent server already covers the self_session tool group,
    # so the dedicated self-session server is deduped away (no duplicate Zimmer server).
    assert_nil result.dig("mcpServers", SELF_SESSION_SERVER),
      "Self-session server should be deduped when the subagent Zimmer server is present"
    assert_equal [ SUBAGENT_SERVER ], processor.injected_mcp_servers
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

    self_server = read_config.dig("mcpServers", SELF_SESSION_SERVER)
    assert_not_nil self_server, "Self-session Zimmer server should be injected"
    assert_equal "http", self_server["type"]
    assert_equal self_session_url, self_server["url"]
    assert_equal({ "X-API-Key" => "local-test-key" }, self_server["headers"])
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  test "ensure_baseline! writes the self-session server as a native http entry, not an npx stdio process" do
    # Zimmer speaks MCP itself: nothing is spawned to reach it, so the injected
    # entry must carry no command/args (and therefore never hits the npx rewrite).
    @session.update!(mcp_servers: [], catalog_skills: [])

    build_processor.ensure_baseline!

    self_server = read_config.dig("mcpServers", SELF_SESSION_SERVER)
    assert_nil self_server["command"], "Injected self-session server must not shell out to npx"
    assert_nil self_server["args"], "Injected self-session server must not shell out to npx"
    assert_equal %w[type url headers], self_server.keys
  end

  test "ensure_baseline! still resolves secrets on pre-existing servers" do
    # ensure_baseline! runs resolve_secrets! over the whole table whenever an
    # injection fires, so pre-existing entries get the same treatment as in post_process!.
    @session.update!(mcp_servers: [], catalog_skills: [])
    ENV["BASELINE_TEST_SECRET"] = "resolved_secret"

    write_config(
      "some-npx-server" => {
        "command" => "npx",
        "args" => [ "-y", "some-package" ],
        "env" => { "API_KEY" => "${BASELINE_TEST_SECRET}" }
      }
    )

    build_processor.ensure_baseline!

    entry = read_config.dig("mcpServers", "some-npx-server")
    assert_equal [ "-y", "some-package" ], entry["args"]
    assert_equal "resolved_secret", entry.dig("env", "API_KEY")
  ensure
    ENV.delete("BASELINE_TEST_SECRET")
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
    assert_not_nil result.dig("mcpServers", SELF_SESSION_SERVER),
      "Self-session server should be injected"
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  test "ensure_baseline! does NOT inject alongside a full-surface zimmer server scoped only by allowed_agent_roots" do
    @session.update!(mcp_servers: [], catalog_skills: [])

    write_config(
      SUBAGENT_SERVER => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp?allowed_agent_roots=some-root",
        "headers" => { "X-API-Key" => "test-key" }
      }
    )

    processor = build_processor
    processor.ensure_baseline!

    # allowed_agent_roots restricts which roots can be spawned; it does not scope
    # the tool surface, so this entry still exposes every self_session tool.
    assert_nil read_config.dig("mcpServers", SELF_SESSION_SERVER),
      "Self-session server should NOT be injected when a full-surface Zimmer server is already present"
    assert_empty processor.injected_mcp_servers
  end

  test "ensure_baseline! skips when an unscoped zimmer server is already present" do
    @session.update!(mcp_servers: [], catalog_skills: [])

    write_config(
      SUBAGENT_SERVER => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp",
        "headers" => { "X-API-Key" => "test-key" }
      }
    )

    processor = build_processor
    processor.ensure_baseline!

    assert_nil read_config.dig("mcpServers", SELF_SESSION_SERVER),
      "Self-session server should NOT be injected when an unscoped Zimmer server is present"
    assert_empty processor.injected_mcp_servers
  end

  test "ensure_baseline! injects alongside a scoped zimmer-sessions server in .mcp.json" do
    @session.update!(mcp_servers: [], catalog_skills: [])

    write_config(
      "zimmer-sessions" => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp?tool_groups=sessions",
        "headers" => { "X-API-Key" => "prod-key" }
      }
    )

    processor = build_processor
    processor.ensure_baseline!

    result = read_config
    assert_not_nil result.dig("mcpServers", "zimmer-sessions"),
      "Existing scoped Zimmer server should be preserved"
    self_server = result.dig("mcpServers", SELF_SESSION_SERVER)
    assert_not_nil self_server,
      "Self-session server SHOULD be injected alongside a Zimmer server scoped to other tool groups"
    assert_equal "self_session", query_params(self_server["url"])["tool_groups"]
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  test "ensure_baseline! injects the subagent Zimmer server for a subagent-roots-only root" do
    # catalog-management has NO default_mcp_servers/skills/hooks/plugins, so
    # its regeneration routes through the baseline path. Its only subagent-spawning
    # capability is the auto-injected zimmer server. ensure_baseline! must inject it
    # (with the resolved default_subagent_roots as allowed_agent_roots) or the
    # session loses start_session entirely. This is the primary defect.
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
    zimmer = result.dig("mcpServers", SUBAGENT_SERVER)
    assert_not_nil zimmer,
      "ensure_baseline! must inject the subagent-spawning zimmer server for a subagent-roots root"
    assert_equal "http", zimmer["type"]
    assert_equal "http://localhost:3000/mcp", url_without_query(zimmer["url"])

    allowed = query_params(zimmer["url"])["allowed_agent_roots"].to_s.split(",")
    assert_equal SUBAGENT_ROOTS.sort, allowed.sort

    # The full-surface subagent server already covers the self_session tool
    # group, so the dedicated self-session server is deduped away.
    assert_nil result.dig("mcpServers", SELF_SESSION_SERVER),
      "Self-session server should be deduped when the subagent Zimmer server is present"
    assert_equal [ SUBAGENT_SERVER ], processor.injected_mcp_servers
  end

  test "ensure_baseline! does NOT inject the subagent Zimmer server for a root without default_subagent_roots" do
    # agent-orchestrator root has no default_subagent_roots: only the self-session
    # server should be injected, never the subagent-spawning server.
    @session.update!(mcp_servers: [], catalog_skills: [], metadata: { "agent_root_key" => "agent-orchestrator" })

    processor = build_processor
    processor.ensure_baseline!

    result = read_config
    assert_nil result.dig("mcpServers", SUBAGENT_SERVER),
      "subagent zimmer server must NOT be injected for a root without default_subagent_roots"
    assert_not_nil result.dig("mcpServers", SELF_SESSION_SERVER),
      "Self-session server should still be injected"
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  # ---------------------------------------------------------------------------
  # Env-aware retargeting of Zimmer MCP server entries
  # ---------------------------------------------------------------------------
  # Fundamental problem these tests guard against: mcp.json's `zimmer` /
  # `zimmer-*` entries carry a production URL (https://zimmer.example.com/mcp),
  # and roots.json puts them in default_mcp_servers. A local-dev or staging
  # session inheriting one would orchestrate PRODUCTION Zimmer instead of its own
  # instance. The post-processor rewrites the ORIGIN (and the X-API-Key header) at
  # config-write time, preserving the query-string scoping, so the catalog stays
  # env-agnostic.

  test "post_process! retargets a catalog zimmer entry to the local instance in test env" do
    write_config(
      SUBAGENT_SERVER => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp",
        "headers" => { "X-API-Key" => "prod-key-should-be-replaced" }
      }
    )

    build_processor.post_process!

    zimmer = read_config.dig("mcpServers", SUBAGENT_SERVER)
    assert_equal "http://localhost:3000/mcp?session_id=#{@session.id}", zimmer["url"],
      "The zimmer entry's origin should be retargeted to localhost in test/dev env " \
      "so the session orchestrates the local Zimmer instance, not production, and " \
      "stamped with the session it was written for"
    assert_equal "local-test-key", zimmer.dig("headers", "X-API-Key"),
      "The zimmer entry's API key should be retargeted to the local key in test/dev env"
  end

  test "post_process! retargets all zimmer-* entries and preserves their query-string scoping" do
    write_config(
      SUBAGENT_SERVER => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp",
        "headers" => { "X-API-Key" => "prod-key" }
      },
      "zimmer-sessions" => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp?tool_groups=sessions&allowed_agent_roots=some-root",
        "headers" => { "X-API-Key" => "prod-key" }
      }
    )

    build_processor.post_process!
    result = read_config

    zimmer = result.dig("mcpServers", SUBAGENT_SERVER)
    assert_equal "http://localhost:3000/mcp?session_id=#{@session.id}", zimmer["url"]
    assert_equal "local-test-key", zimmer.dig("headers", "X-API-Key")

    sessions_entry = result.dig("mcpServers", "zimmer-sessions")
    assert_equal "http://localhost:3000/mcp?tool_groups=sessions&allowed_agent_roots=some-root&session_id=#{@session.id}",
      sessions_entry["url"],
      "Retarget must rewrite only the origin — the query string carries the entry's scoping"
    assert_equal "local-test-key", sessions_entry.dig("headers", "X-API-Key")
  end

  test "post_process! creates the headers table on a zimmer entry that has none" do
    # A catalog entry can arrive without headers (e.g. its ${VAR} resolved to blank
    # and was dropped). Retarget must still stamp the current instance's API key.
    write_config(
      "zimmer-sessions" => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp?tool_groups=sessions"
      }
    )

    build_processor.post_process!

    assert_equal "local-test-key",
      read_config.dig("mcpServers", "zimmer-sessions", "headers", "X-API-Key")
  end

  test "post_process! does NOT retarget non-Zimmer entries" do
    write_config(
      "playwright-custom" => {
        "command" => "npx",
        "args" => [ "-y", "@anthropic/playwright-mcp-server" ],
        "env" => {
          "SOMETHING_BASE_URL" => "https://example.com",
          "SOMETHING_API_KEY" => "do-not-touch"
        }
      },
      # A third-party server that happens to be served at /mcp must not be
      # mistaken for one of ours: the match is on the entry name, not the URL.
      "figma" => {
        "type" => "http",
        "url" => "https://mcp.figma.com/mcp",
        "headers" => { "Authorization" => "do-not-touch" }
      }
    )

    build_processor.post_process!
    result = read_config

    pw = result.dig("mcpServers", "playwright-custom")
    assert_equal "https://example.com", pw.dig("env", "SOMETHING_BASE_URL"),
      "Non-Zimmer servers must not be touched by retargeting"
    assert_equal "do-not-touch", pw.dig("env", "SOMETHING_API_KEY"),
      "Non-Zimmer servers must not be touched by retargeting"

    figma = result.dig("mcpServers", "figma")
    assert_equal "https://mcp.figma.com/mcp", figma["url"],
      "A third-party server served at /mcp must not be retargeted at Zimmer"
    assert_equal({ "Authorization" => "do-not-touch" }, figma["headers"])
  end

  test "post_process! does NOT retarget in production env" do
    # Rails.env is a framework primitive (not internal application code), and there
    # is no clean dependency-injection seam for it on a class method. Stubbing it
    # here is the simplest way to exercise the env-conditional branch.
    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      write_config(
        SUBAGENT_SERVER => {
          "type" => "http",
          "url" => "https://zimmer.example.com/mcp",
          "headers" => { "X-API-Key" => "real-prod-key" }
        }
      )

      build_processor.post_process!

      zimmer = read_config.dig("mcpServers", SUBAGENT_SERVER)
      assert_equal "https://zimmer.example.com/mcp?session_id=#{@session.id}", zimmer["url"],
        "In production env, a zimmer entry's origin and key must be pass-through " \
        "(the catalog already points at the right place) — only the session stamp is added"
      assert_equal "real-prod-key", zimmer.dig("headers", "X-API-Key"),
        "In production env, a zimmer entry's API key must be pass-through"
    end
  end

  test "post_process! retargets a zimmer entry to the staging instance in staging env" do
    ENV["ZIMMER_STAGING_BASE_URL"] = "https://staging.zimmer.example.com"
    ENV["ZIMMER_STAGING_API_KEY"] = "test-staging-api-key"

    Rails.stub(:env, ActiveSupport::StringInquirer.new("staging")) do
      write_config(
        "zimmer-sessions" => {
          "type" => "http",
          "url" => "https://zimmer.example.com/mcp?tool_groups=sessions",
          "headers" => { "X-API-Key" => "prod-key-not-staging" }
        }
      )

      build_processor.post_process!

      entry = read_config.dig("mcpServers", "zimmer-sessions")
      assert_equal "https://staging.zimmer.example.com/mcp?tool_groups=sessions&session_id=#{@session.id}", entry["url"],
        "In staging env, a zimmer entry should be retargeted to the staging instance"
      assert_equal "test-staging-api-key", entry.dig("headers", "X-API-Key"),
        "In staging env, a zimmer entry should carry the staging key"
    end
  end

  test "the injected subagent server points at the local instance in dev/test env" do
    # When a parent root with default_subagent_roots spawns subagents, the
    # auto-injected zimmer MCP server must point at the LOCAL Zimmer instance in
    # dev, not production.
    @session.update!(metadata: { "agent_root_key" => "catalog-management" })

    write_config("noop" => { "command" => "true", "args" => [], "env" => {} })

    build_processor.post_process!

    injected = read_config.dig("mcpServers", SUBAGENT_SERVER)
    assert_not_nil injected, "Subagent Zimmer server should be injected for catalog-management"
    assert_equal "http://localhost:3000/mcp", url_without_query(injected["url"]),
      "Auto-injected subagent Zimmer server must target the local instance, not prod"
    assert_equal "local-test-key", injected.dig("headers", "X-API-Key"),
      "Auto-injected subagent Zimmer server must carry the local key, not the prod key"
    assert_not_nil query_params(injected["url"])["allowed_agent_roots"],
      "Auto-injected subagent Zimmer server must keep its allowed_agent_roots scoping"
  end

  test "the injected subagent server points at the prod instance in production env" do
    ENV["ZIMMER_PROD_API_KEY"] = "real-prod-key"
    @session.update!(metadata: { "agent_root_key" => "catalog-management" })

    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      write_config("noop" => { "command" => "true", "args" => [], "env" => {} })

      build_processor.post_process!

      injected = read_config.dig("mcpServers", SUBAGENT_SERVER)
      assert_not_nil injected
      assert_equal "https://zimmer.example.com/mcp", url_without_query(injected["url"])
      assert_equal "real-prod-key", injected.dig("headers", "X-API-Key")
    end
  end

  test "retarget honors ZIMMER_LOCAL_BASE_URL override" do
    ENV["ZIMMER_LOCAL_BASE_URL"] = "http://localhost:9999"

    write_config(
      "zimmer-sessions" => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp?tool_groups=sessions",
        "headers" => { "X-API-Key" => "prod-key" }
      }
    )

    build_processor.post_process!
    result = read_config

    assert_equal "http://localhost:9999/mcp?tool_groups=sessions&session_id=#{@session.id}",
      result.dig("mcpServers", "zimmer-sessions", "url"),
      "When ZIMMER_LOCAL_BASE_URL is set, retarget should use that exact origin"
    assert_equal "http://localhost:9999/mcp?session_id=#{@session.id}&tool_groups=self_session",
      result.dig("mcpServers", SELF_SESSION_SERVER, "url"),
      "The injected self-session entry should be built against the same overridden origin"
  end

  test "ensure_baseline! injection + retarget produces a localhost-targeted self-session entry in dev env" do
    # The bug class this guards: Zimmer running locally, but the auto-injected
    # self-session MCP server points at the production URL and gets a 401.
    @session.update!(mcp_servers: [])

    write_config({})

    build_processor.ensure_baseline!

    self_session = read_config.dig("mcpServers", SELF_SESSION_SERVER)
    assert_not_nil self_session, "ensure_baseline! should inject the self-session entry"
    assert_equal self_session_url, self_session["url"],
      "Self-session URL must target localhost in dev, not zimmer.example.com — and keep its tool_groups scoping"
    assert_equal "local-test-key", self_session.dig("headers", "X-API-Key"),
      "Self-session API key must be the local key in dev, not the prod key"
  end

  test "post_process! logs warning when retargeting with blank API key" do
    ENV.delete("ZIMMER_LOCAL_API_KEY")

    write_config(
      SUBAGENT_SERVER => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp",
        "headers" => { "X-API-Key" => "prod-key" }
      }
    )

    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    build_processor.post_process!

    assert_match(/Retargeted Zimmer MCP servers.*blank API key/,
      log_output.string,
      "Expected warning when the API key is blank after retarget")
    assert_match(/ZIMMER_LOCAL_API_KEY/,
      log_output.string,
      "Warning should name the env var the dev needs to set")
  ensure
    Rails.logger = original_logger if original_logger
  end

  test "post_process! does NOT warn when retargeted API key is present" do
    write_config(
      SUBAGENT_SERVER => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp",
        "headers" => { "X-API-Key" => "prod-key" }
      }
    )

    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    build_processor.post_process!

    refute_match(/blank API key/, log_output.string,
      "Should not warn when the API key is present after retarget")
  ensure
    Rails.logger = original_logger if original_logger
  end

  # ---------------------------------------------------------------------------
  # Golden file — byte-for-byte stability of the written .mcp.json
  # ---------------------------------------------------------------------------
  # Locks in the exact serialized output for a representative config so any future
  # change to the post-processor cannot silently alter the bytes Zimmer writes.
  # The input deliberately includes a full-surface Zimmer server so self-session
  # injection is deduped away — this keeps the output independent of the runtime
  # catalog and fully deterministic.
  test "post_process! produces byte-for-byte stable .mcp.json (golden file)" do
    ENV["ZIMMER_LOCAL_API_KEY"] = "local-key"

    write_config(
      SUBAGENT_SERVER => {
        "type" => "http",
        "url" => "https://zimmer.example.com/mcp",
        "headers" => { "X-API-Key" => "prod-key" }
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
        SUBAGENT_SERVER => {
          "type" => "http",
          "url" => "http://localhost:3000/mcp?session_id=#{@session.id}",
          "headers" => { "X-API-Key" => "local-key" }
        },
        "some-npx-server" => {
          "command" => "npx",
          "args" => [ "-y", "some-package" ],
          "env" => {
            "TOKEN" => "fallback",
            "ELICITATION_REQUEST_URL" => ElicitationEndpoint.url,
            "ELICITATION_POLL_URL" => ElicitationEndpoint.url,
            "ELICITATION_PREFER_HTTP_FALLBACK" => "true",
            "ELICITATION_TTL_MS" => (Elicitation::DEFAULT_EXPIRATION.to_i * 1000).to_s,
            "ELICITATION_SESSION_ID" => @session.id.to_s
          }
        }
      }
    }

    assert_equal JSON.pretty_generate(expected),
      @mock_fs.read(File.join(@working_dir, ".mcp.json")),
      "Written .mcp.json must match the golden serialization byte-for-byte"
  end

  # ---------------------------------------------------------------------------
  # Per-server npm cache for servers that share an npx package
  #
  # Regression for prod session 4668: the `zimmer-router` root carries both
  # 1Password servers, both run the byte-identical `npx -y onepassword-mcp-server@latest`,
  # and on a cold clone the two installs raced the same `_npx/<hash>` directory.
  # The loser died with ENOTEMPTY, which killed the agent process five seconds
  # into the session's first turn.
  # ---------------------------------------------------------------------------

  test "post_process! gives each of two servers sharing an npx package its own npm cache" do
    write_config(
      "1password-tadas-rw" => { "command" => "npx", "args" => [ "-y", "onepassword-mcp-server@latest" ] },
      "1password-pulsemcp-rw" => { "command" => "npx", "args" => [ "-y", "onepassword-mcp-server@latest" ] }
    )

    build_processor.post_process!

    servers = read_config["mcpServers"]
    tadas_cache = servers.dig("1password-tadas-rw", "env", "NPM_CONFIG_CACHE")
    pulsemcp_cache = servers.dig("1password-pulsemcp-rw", "env", "NPM_CONFIG_CACHE")

    assert tadas_cache.present?, "colliding server should be given its own NPM_CONFIG_CACHE"
    assert pulsemcp_cache.present?, "colliding server should be given its own NPM_CONFIG_CACHE"
    assert_not_equal tadas_cache, pulsemcp_cache,
      "two servers sharing an npx package must not share an _npx cache directory — " \
      "that is exactly the race that killed session 4668"
    assert tadas_cache.start_with?(File.join(@working_dir, ".npm-cache")),
      "the isolated cache must stay inside the clone so CacheClearService still reclaims it"
  end

  # The common case must stay byte-identical: one shared per-clone cache, so npm
  # still downloads each tarball once.
  test "post_process! leaves a lone npx server on the shared per-clone npm cache" do
    write_config(
      "context7" => { "command" => "npx", "args" => [ "-y", "@upstash/context7-mcp@latest" ] },
      "playwright-custom" => { "command" => "npx", "args" => [ "-y", "@playwright/mcp@latest" ] }
    )

    build_processor.post_process!

    servers = read_config["mcpServers"]
    assert_nil servers.dig("context7", "env", "NPM_CONFIG_CACHE")
    assert_nil servers.dig("playwright-custom", "env", "NPM_CONFIG_CACHE")
  end

  test "post_process! does not override an npm cache the catalog entry set explicitly" do
    write_config(
      "a" => {
        "command" => "npx",
        "args" => [ "-y", "shared-pkg@latest" ],
        "env" => { "NPM_CONFIG_CACHE" => "/operators/choice" }
      },
      "b" => { "command" => "npx", "args" => [ "-y", "shared-pkg@latest" ] }
    )

    build_processor.post_process!

    servers = read_config["mcpServers"]
    assert_equal "/operators/choice", servers.dig("a", "env", "NPM_CONFIG_CACHE")
    assert_not_equal "/operators/choice", servers.dig("b", "env", "NPM_CONFIG_CACHE")
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

  # The /mcp endpoint of the instance under test, scoped to the self-session tools
  # and stamped with the session the config is being written for. Query order is
  # SelfSessionInjector's — Hash#to_query sorts its keys.
  def self_session_url(session = @session)
    "http://localhost:3000/mcp?session_id=#{session.id}&tool_groups=self_session"
  end

  def query_params(url)
    Rack::Utils.parse_query(URI.parse(url).query)
  end

  def url_without_query(url)
    url.to_s.split("?").first
  end
end
