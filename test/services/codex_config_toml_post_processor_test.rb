# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests for CodexConfigTomlPostProcessor — the runtime post-processor that
# applies Zimmer-specific tweaks to the `.codex/config.toml` AIR writes for OpenAI
# Codex sessions. Like the Claude processor, these exercise the processor
# directly (no AIR CLI / Open3): it only reads, mutates, and writes the TOML
# config via the injected file system.
#
# Two Codex-specific behaviors are under test:
#
#   1. The host-env-forwarding rewrite: Codex servers forward host process env via
#      `env_vars`/`env_http_headers`, but Zimmer's secrets live in Rails encrypted
#      credentials (SecretsLoader), not the Codex process's host env. The processor
#      must move every SecretsLoader-backed var OUT of those forwarding fields and
#      INTO the literal `env`/`http_headers` tables with the resolved value, while
#      leaving genuine host-env vars in place.
#
#   2. The native shape of Zimmer's own MCP entries. Zimmer serves MCP itself, so
#      the auto-injected servers are streamable-HTTP entries pointing back at this
#      instance's /mcp endpoint. Codex infers the transport from the presence of
#      `url` (no `type` discriminator) and keeps literal headers under `http_headers`.
class CodexConfigTomlPostProcessorTest < ActiveSupport::TestCase
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
      metadata: { "agent_root_key" => "agent-orchestrator" },
      agent_runtime: "codex"
    )
    @working_dir = Dir.mktmpdir
    @mock_fs = MockFileSystemAdapter.new

    @original_env = ENV.to_hash.slice(*MANAGED_ENV_VARS)
    MANAGED_ENV_VARS.each { |var| ENV.delete(var) }
    # Tests run with Rails.env == "test", which resolves to the LOCAL instance.
    ENV["ZIMMER_LOCAL_API_KEY"] = "local-key"
  end

  teardown do
    FileUtils.rm_rf(@working_dir) if @working_dir && File.exist?(@working_dir)
    MANAGED_ENV_VARS.each { |var| ENV.delete(var) }
    @original_env.each { |var, value| ENV[var] = value }
  end

  # ---------------------------------------------------------------------------
  # Codex host-env forwarding → literal tables
  # ---------------------------------------------------------------------------

  test "post_process! inlines SecretsLoader-backed env_vars into env and retains non-secret forwarding" do
    stub_secrets("ACME_API_KEY" => "sk-acme-123")

    write_config(
      "acme-server" => {
        "command" => "npx",
        "args" => [ "-y", "@acme/mcp" ],
        "env" => {},
        # ACME_API_KEY is a Zimmer secret → inline it; ACME_HOST_REGION is a genuine
        # host-env var Codex should forward at launch → leave it in env_vars.
        "env_vars" => [ "ACME_API_KEY", "ACME_HOST_REGION" ]
      }
    )

    build_processor.post_process!

    entry = read_config.dig("mcp_servers", "acme-server")
    assert_equal "sk-acme-123", entry.dig("env", "ACME_API_KEY"),
      "SecretsLoader-backed var must be inlined into the literal env table with its resolved value"
    assert_equal [ "ACME_HOST_REGION" ], entry["env_vars"],
      "Non-secret host-env var must remain in env_vars for Codex to forward at launch"
  end

  # Codex does not hand a stdio MCP server its own environment the way Claude Code does:
  # it builds the child env from a fixed whitelist (HOME, PATH, LANG, …) plus exactly the
  # vars the entry names in `env_vars`. SSH_PRIVATE_KEY_PATH is in neither, so without
  # this forwarding an ssh-* server under a Codex session would still see no key — the
  # bug OperatorSshKeyProvisioner exists to fix, fixed only for Claude.
  test "post_process! forwards SSH_PRIVATE_KEY_PATH to stdio servers when an operator key is provisioned" do
    OperatorSshKeyProvisioner.stubs(:ensure!).returns("/home/rails/.ssh/zimmer_operator_ed25519")
    stub_secrets({})

    write_config(
      "ssh-staging" => { "command" => "npx", "args" => [ "-y", "ssh-agent-mcp-server" ], "env" => { "SSH_HOST" => "staging.example.com" } },
      "acme-server" => { "command" => "npx", "args" => [ "-y", "@acme/mcp" ], "env_vars" => [ "ACME_HOST_REGION" ] },
      "hosted" => { "url" => "https://mcp.example.com/mcp" }
    )

    build_processor.post_process!

    config = read_config
    assert_equal [ "SSH_PRIVATE_KEY_PATH" ], config.dig("mcp_servers", "ssh-staging", "env_vars")
    assert_equal [ "ACME_HOST_REGION", "SSH_PRIVATE_KEY_PATH" ], config.dig("mcp_servers", "acme-server", "env_vars"),
      "forwarding must be added alongside the entry's own host-env vars, not replace them"
    assert_nil config.dig("mcp_servers", "hosted", "env_vars"),
      "an HTTP server has no child environment to forward into"
  end

  test "post_process! forwards nothing when no operator SSH key is provisioned" do
    OperatorSshKeyProvisioner.stubs(:ensure!).returns(nil)
    stub_secrets({})

    write_config("acme-server" => { "command" => "npx", "args" => [ "-y", "@acme/mcp" ] })

    build_processor.post_process!

    assert_nil read_config.dig("mcp_servers", "acme-server", "env_vars")
  end

  test "post_process! drops env_vars entirely when every forwarded var is a Zimmer secret" do
    stub_secrets("ACME_API_KEY" => "sk-acme-123", "ACME_DB_URL" => "postgres://x")

    write_config(
      "acme-server" => {
        "command" => "npx",
        "args" => [ "-y", "@acme/mcp" ],
        "env" => {},
        "env_vars" => [ "ACME_API_KEY", "ACME_DB_URL" ]
      }
    )

    build_processor.post_process!

    entry = read_config.dig("mcp_servers", "acme-server")
    assert_nil entry["env_vars"],
      "env_vars must be removed when no genuine host-env forwarding remains"
    assert_equal "sk-acme-123", entry.dig("env", "ACME_API_KEY")
    assert_equal "postgres://x", entry.dig("env", "ACME_DB_URL")
  end

  test "post_process! inlines SecretsLoader-backed env_http_headers into http_headers and retains non-secret forwarding" do
    stub_secrets("ACME_TOKEN" => "tok-acme-xyz")

    write_config(
      "acme-http" => {
        "url" => "https://acme.example.com/mcp",
        "http_headers" => {},
        "env_http_headers" => { "Authorization" => "ACME_TOKEN", "X-Region" => "ACME_REGION" }
      }
    )

    build_processor.post_process!

    entry = read_config.dig("mcp_servers", "acme-http")
    assert_equal "tok-acme-xyz", entry.dig("http_headers", "Authorization"),
      "SecretsLoader-backed header var must be inlined into http_headers with its resolved value"
    assert_equal({ "X-Region" => "ACME_REGION" }, entry["env_http_headers"],
      "Non-secret header forwarding must remain in env_http_headers")
  end

  # Regression: AIR turns a whole-value ${VAR} header ref into an env_http_headers
  # forwarding rule naming the catalog's (production) var. Retargeting writes the
  # *local* key into http_headers, and inline_forwarded_env_http_headers! would then
  # overwrite it with the production key — handing a dev session prod credentials.
  test "post_process! does not let AIR's header forwarding clobber a retargeted Zimmer key" do
    stub_secrets("ZIMMER_PROD_API_KEY" => "prod-key-do-not-use")

    write_config(
      "zimmer-sessions" => {
        "url" => "https://zimmer.example.com/mcp?tool_groups=sessions",
        "http_headers" => {},
        "env_http_headers" => { "X-API-Key" => "ZIMMER_PROD_API_KEY" }
      }
    )

    build_processor.post_process!

    entry = read_config.dig("mcp_servers", "zimmer-sessions")
    assert_equal "local-key", entry.dig("http_headers", "X-API-Key"),
      "the retargeted local key must survive AIR's header forwarding"
    assert_nil entry["env_http_headers"],
      "the forwarding rule naming the prod key must be dropped when the entry is retargeted"
    assert_includes entry["url"], "http://localhost", "the entry must point at this instance"
    assert_includes entry["url"], "tool_groups=sessions", "scoping must survive retargeting"
  end

  test "post_process! injects npx --prefix /tmp into Codex stdio servers" do
    write_config(
      "acme-server" => {
        "command" => "npx",
        "args" => [ "-y", "@acme/mcp" ],
        "env" => {}
      }
    )

    build_processor.post_process!

    args = read_config.dig("mcp_servers", "acme-server", "args")
    assert_includes args, "--prefix"
    assert_includes args, "/tmp"
  end

  test "post_process! resolves ${VAR} interpolations AIR left literal in env" do
    ENV["CODEX_TEST_SECRET"] = "resolved_secret"

    write_config(
      "renamed-server" => {
        "command" => "node",
        "args" => [ "server.js" ],
        # A renamed/partial ref AIR cannot convert to host-env forwarding stays
        # literal in env as a ${VAR} that this processor must resolve.
        "env" => {
          "API_KEY" => "${CODEX_TEST_SECRET}",
          "WITH_DEFAULT" => "${CODEX_MISSING_VAR:-fallback_value}"
        }
      }
    )

    build_processor.post_process!

    env = read_config.dig("mcp_servers", "renamed-server", "env")
    assert_equal "resolved_secret", env["API_KEY"]
    assert_equal "fallback_value", env["WITH_DEFAULT"]
  ensure
    ENV.delete("CODEX_TEST_SECRET")
  end

  test "post_process! resolves ${VAR} interpolations AIR left literal in http_headers" do
    ENV["CODEX_HEADER_TOKEN"] = "tok-123"

    write_config(
      "acme-http" => {
        "url" => "https://acme.example.com/mcp",
        "http_headers" => { "Authorization" => "${CODEX_HEADER_TOKEN}" }
      }
    )

    build_processor.post_process!

    assert_equal "tok-123", read_config.dig("mcp_servers", "acme-http", "http_headers", "Authorization"),
      "Codex keeps literal headers under http_headers — they must be resolved too"
  ensure
    ENV.delete("CODEX_HEADER_TOKEN")
  end

  # ---------------------------------------------------------------------------
  # Injection: the self-session and subagent Zimmer servers
  # ---------------------------------------------------------------------------

  test "post_process! injects the self-session Zimmer server for a codex session" do
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

    self_server = read_config.dig("mcp_servers", SELF_SESSION_SERVER)
    assert_not_nil self_server, "self-session Zimmer server should be injected for codex sessions"
    # Zimmer speaks MCP natively: the entry is an HTTP server, not an npx process.
    assert_nil self_server["command"], "Injected self-session server must not shell out to npx"
    assert_nil self_server["args"], "Injected self-session server must not shell out to npx"
    assert_nil self_server["type"], "Codex infers the transport from `url` — no type discriminator"
    assert_equal "http://localhost:3000/mcp?tool_groups=self_session", self_server["url"],
      "self-session URL must target the local instance in the test env, scoped to the self_session tools"
    assert_equal({ "X-API-Key" => "local-key" }, self_server["http_headers"],
      "Codex carries literal headers under http_headers")
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  test "post_process! injects the self-session server alongside a scoped zimmer-sessions server" do
    write_config(
      "zimmer-sessions" => {
        "url" => "https://zimmer.example.com/mcp?tool_groups=sessions",
        "http_headers" => { "X-API-Key" => "prod-key" }
      }
    )

    processor = build_processor
    processor.post_process!

    self_server = read_config.dig("mcp_servers", SELF_SESSION_SERVER)
    assert_not_nil self_server,
      "A Zimmer server scoped to other tool groups does not cover self_session — inject anyway"
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  test "post_process! does NOT inject the self-session server alongside a full-surface zimmer server" do
    write_config(
      SUBAGENT_SERVER => {
        "url" => "https://zimmer.example.com/mcp",
        "http_headers" => { "X-API-Key" => "prod-key" }
      }
    )

    processor = build_processor
    processor.post_process!

    assert_nil read_config.dig("mcp_servers", SELF_SESSION_SERVER),
      "A full-surface Zimmer server already exposes every self_session tool"
    assert_empty processor.injected_mcp_servers
  end

  test "post_process! synthesizes a baseline config with the self-session server when AIR wrote none" do
    # A skills-only session takes the prepare! branch but AIR writes no config.
    # post_process! must synthesize one and inject the self-session server rather
    # than leaving the session with no Zimmer tools (mirrors the Claude processor).
    @session.update!(mcp_servers: [], catalog_skills: [ "zimmer-run-tests" ], metadata: { "agent_root_key" => "agent-orchestrator" })

    processor = build_processor
    processor.post_process!

    assert @mock_fs.exists?(config_file_path),
      "post_process! should synthesize the Codex config when AIR wrote none"
    self_server = read_config.dig("mcp_servers", SELF_SESSION_SERVER)
    assert_not_nil self_server, "Self-session Zimmer server should be injected into the synthesized config"
    assert_equal "http://localhost:3000/mcp?tool_groups=self_session", self_server["url"]
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  test "post_process! injects the subagent Zimmer server when AIR wrote no Codex config for a subagent-roots root" do
    # Secondary defect, Codex flavor: a subagent-roots root with skills (prepare!
    # branch) but no explicit MCP servers gets no config from AIR. The subagent
    # spawning server must still be injected — not gated on an AIR-produced file.
    @session.update!(
      mcp_servers: [],
      catalog_skills: [ "zimmer-run-tests" ],
      metadata: { "agent_root_key" => "catalog-management" }
    )

    processor = build_processor
    processor.post_process!

    assert @mock_fs.exists?(config_file_path)
    zimmer = read_config.dig("mcp_servers", SUBAGENT_SERVER)
    assert_not_nil zimmer,
      "subagent-spawning zimmer server must be injected even without an AIR-produced config"
    assert_equal "http://localhost:3000/mcp", url_without_query(zimmer["url"])

    params = query_params(zimmer["url"])
    assert_nil params["tool_groups"], "The subagent server is full-surface"
    assert_equal SUBAGENT_ROOTS.sort, params["allowed_agent_roots"].split(",").sort
    assert_equal({ "X-API-Key" => "local-key" }, zimmer["http_headers"])

    # Full-surface subagent server already covers the self_session tool group.
    assert_nil read_config.dig("mcp_servers", SELF_SESSION_SERVER),
      "Self-session server should be deduped when the subagent Zimmer server is present"
    assert_equal [ SUBAGENT_SERVER ], processor.injected_mcp_servers
  end

  test "post_process! does NOT overwrite a catalog-provided unrestricted zimmer entry for a subagent-roots root" do
    # Codex flavor of the same-key clobber guard: a subagent-roots root whose
    # catalog ships an unrestricted, full-surface `zimmer` entry must keep it —
    # injecting our root-restricted URL over the same key would silently narrow
    # start_session's allowed_agent_roots.
    @session.update!(metadata: { "agent_root_key" => "catalog-management" })

    write_config(
      SUBAGENT_SERVER => {
        "url" => "https://zimmer.example.com/mcp",
        "http_headers" => { "X-API-Key" => "prod-key" }
      }
    )

    processor = build_processor
    processor.post_process!

    zimmer = read_config.dig("mcp_servers", SUBAGENT_SERVER)
    assert_not_nil zimmer, "The catalog-provided zimmer entry must survive"
    assert_nil query_params(zimmer["url"])["allowed_agent_roots"],
      "The catalog's unrestricted entry must NOT be narrowed to the root's subagent list"
    assert_equal "http://localhost:3000/mcp", url_without_query(zimmer["url"]),
      "The surviving catalog entry is still retargeted at the local instance"
    assert_empty processor.injected_mcp_servers,
      "Nothing is injected when a catalog zimmer entry already covers the surface"
  end

  test "ensure_baseline! creates .codex/config.toml with the self-session server when none exists" do
    @session.update!(mcp_servers: [])

    refute @mock_fs.exists?(config_file_path)

    processor = build_processor
    processor.ensure_baseline!

    assert @mock_fs.exists?(config_file_path),
      "ensure_baseline! must create the Codex config in its .codex/ subdirectory"
    self_server = read_config.dig("mcp_servers", SELF_SESSION_SERVER)
    assert_not_nil self_server, "ensure_baseline! should inject the self-session entry"
    assert_equal "http://localhost:3000/mcp?tool_groups=self_session", self_server["url"]
    assert_equal({ "X-API-Key" => "local-key" }, self_server["http_headers"])
    assert_equal [ SELF_SESSION_SERVER ], processor.injected_mcp_servers
  end

  # ---------------------------------------------------------------------------
  # Env-aware retargeting of Zimmer MCP server entries
  # ---------------------------------------------------------------------------

  test "post_process! retargets a catalog zimmer entry at the current instance, preserving its query string" do
    write_config(
      "zimmer-sessions" => {
        "url" => "https://zimmer.example.com/mcp?tool_groups=sessions",
        "http_headers" => { "X-API-Key" => "prod-key-should-be-replaced" }
      }
    )

    build_processor.post_process!

    entry = read_config.dig("mcp_servers", "zimmer-sessions")
    assert_equal "http://localhost:3000/mcp?tool_groups=sessions", entry["url"],
      "Only the origin is rewritten — the query string carries the entry's scoping"
    assert_equal "local-key", entry.dig("http_headers", "X-API-Key"),
      "Retarget stamps the current instance's API key into Codex's http_headers table"
  end

  test "post_process! creates the http_headers table on a zimmer entry that has none" do
    write_config(
      "zimmer-sessions" => { "url" => "https://zimmer.example.com/mcp?tool_groups=sessions" }
    )

    build_processor.post_process!

    entry = read_config.dig("mcp_servers", "zimmer-sessions")
    assert_equal "local-key", entry.dig("http_headers", "X-API-Key")
    assert_nil entry["headers"],
      "Codex has no `headers` key — the API key must land in http_headers"
  end

  test "post_process! does NOT retarget non-Zimmer entries" do
    write_config(
      # A third-party server that happens to be served at /mcp must not be
      # mistaken for one of ours: the match is on the entry name, not the URL.
      "figma" => {
        "url" => "https://mcp.figma.com/mcp",
        "http_headers" => { "Authorization" => "do-not-touch" }
      }
    )

    build_processor.post_process!

    figma = read_config.dig("mcp_servers", "figma")
    assert_equal "https://mcp.figma.com/mcp", figma["url"],
      "A third-party server served at /mcp must not be retargeted at Zimmer"
    assert_equal({ "Authorization" => "do-not-touch" }, figma["http_headers"])
    assert_nil figma["http_headers"]["X-API-Key"], "Zimmer's API key must not leak into a third-party server"
  end

  test "post_process! does NOT retarget in production env" do
    ENV["ZIMMER_PROD_API_KEY"] = "real-prod-key"

    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      write_config(
        SUBAGENT_SERVER => {
          "url" => "https://zimmer.example.com/mcp",
          "http_headers" => { "X-API-Key" => "prod-key" }
        }
      )

      build_processor.post_process!

      entry = read_config.dig("mcp_servers", SUBAGENT_SERVER)
      assert_equal "https://zimmer.example.com/mcp", entry["url"],
        "In production the catalog URL already points at the instance serving the session"
      assert_equal "prod-key", entry.dig("http_headers", "X-API-Key")
    end
  end

  # ---------------------------------------------------------------------------
  # Golden file — byte-for-byte stability of the written .codex/config.toml
  # ---------------------------------------------------------------------------
  # Locks in the exact serialized TOML for a representative config so any future
  # change to the post-processor or the TOML serializer cannot silently alter
  # the bytes Zimmer writes. The input includes a full-surface Zimmer server so
  # self-session injection is deduped away — this keeps the output independent of
  # the runtime catalog and fully deterministic. It exercises every Codex-specific
  # path: retargeting a native Zimmer http entry, env_vars secret inlining (with
  # retained host-env forwarding), env_http_headers secret inlining, and the npx
  # --prefix /tmp rewrite.
  test "post_process! produces byte-for-byte stable .codex/config.toml (golden file)" do
    stub_secrets("ACME_API_KEY" => "sk-acme-123", "ACME_TOKEN" => "tok-acme-xyz")

    write_config(
      SUBAGENT_SERVER => {
        "url" => "https://zimmer.example.com/mcp",
        "http_headers" => { "X-API-Key" => "prod-key" }
      },
      "acme-server" => {
        "command" => "npx",
        "args" => [ "-y", "@acme/mcp" ],
        "env" => {},
        "env_vars" => [ "ACME_API_KEY", "ACME_HOST_REGION" ]
      },
      "acme-http" => {
        "url" => "https://acme.example.com/mcp",
        "http_headers" => {},
        "env_http_headers" => { "Authorization" => "ACME_TOKEN", "X-Region" => "ACME_REGION" }
      }
    )

    build_processor.post_process!

    expected = <<~TOML
      [mcp_servers.acme-http]
      url = "https://acme.example.com/mcp"
      [mcp_servers.acme-http.env_http_headers]
      X-Region = "ACME_REGION"
      [mcp_servers.acme-http.http_headers]
      Authorization = "tok-acme-xyz"
      [mcp_servers.acme-server]
      args = ["-y", "--prefix", "/tmp", "@acme/mcp"]
      command = "npx"
      env_vars = ["ACME_HOST_REGION"]
      [mcp_servers.acme-server.env]
      ACME_API_KEY = "sk-acme-123"
      [mcp_servers.zimmer]
      url = "http://localhost:3000/mcp"
      [mcp_servers.zimmer.http_headers]
      X-API-Key = "local-key"
    TOML

    assert_equal expected, @mock_fs.read(config_file_path),
      "Written .codex/config.toml must match the golden serialization byte-for-byte"
  end

  private

  def build_processor
    CodexConfigTomlPostProcessor.new(
      session: @session,
      working_directory: @working_dir,
      file_system: @mock_fs
    )
  end

  def config_file_path
    File.join(@working_dir, ".codex", "config.toml")
  end

  def write_config(servers)
    @mock_fs.write(config_file_path, TomlRB.dump("mcp_servers" => servers))
  end

  def read_config
    TomlRB.parse(@mock_fs.read(config_file_path))
  end

  def query_params(url)
    Rack::Utils.parse_query(URI.parse(url).query)
  end

  def url_without_query(url)
    url.to_s.split("?").first
  end

  # Stub SecretsLoader so the host-env-forwarding inline logic is deterministic:
  # only the named vars are Zimmer secrets; everything else is a genuine host-env var.
  def stub_secrets(values)
    SecretsLoader.stubs(:exists?).returns(false)
    SecretsLoader.stubs(:get).returns(nil)
    values.each do |name, value|
      SecretsLoader.stubs(:exists?).with(name).returns(true)
      SecretsLoader.stubs(:get).with(name).returns(value)
    end
  end
end
