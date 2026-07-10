# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests for CodexConfigTomlPostProcessor — the runtime post-processor that
# applies Zimmer-specific tweaks to the `.codex/config.toml` AIR writes for OpenAI
# Codex sessions. Like the Claude processor, these exercise the processor
# directly (no AIR CLI / Open3): it only reads, mutates, and writes the TOML
# config via the injected file system.
#
# The Codex-specific behavior under test is the host-env-forwarding rewrite:
# Codex servers forward host process env via `env_vars`/`env_http_headers`, but
# Zimmer's secrets live in Rails encrypted credentials (SecretsLoader), not the
# Codex process's host env. The processor must move every SecretsLoader-backed
# var OUT of those forwarding fields and INTO the literal `env`/`http_headers`
# tables with the resolved value, while leaving genuine host-env vars in place.
class CodexConfigTomlPostProcessorTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:active_session)
    @session.update!(
      mcp_servers: [ "playwright-custom" ],
      catalog_skills: [ "wait-for-ci" ],
      metadata: { "agent_root_key" => "agent-orchestrator" },
      agent_runtime: "codex"
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

  test "post_process! injects the self-session Zimmer server for a codex session" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-key"
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

    self_server = read_config.dig("mcp_servers", "agent-orchestrator-staging-self-session")
    assert_not_nil self_server, "self-session Zimmer server should be injected for codex sessions"
    assert_equal "npx", self_server["command"]
    assert_includes self_server["args"], "agent-orchestrator-mcp-server@latest"
    assert_includes self_server["args"], "--prefix"
    assert_includes self_server["args"], "/tmp"
    assert_equal "self_session", self_server.dig("env", "TOOL_GROUPS")
    assert_equal "http://localhost:3000", self_server.dig("env", "AGENT_ORCHESTRATOR_BASE_URL"),
      "self-session BASE_URL must be retargeted to localhost in the test env"
    assert_equal "local-key", self_server.dig("env", "AGENT_ORCHESTRATOR_API_KEY"),
      "self-session API_KEY must be retargeted to the local key in the test env"
    assert_equal [ "agent-orchestrator-staging-self-session" ], processor.injected_mcp_servers
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
  end

  test "post_process! synthesizes a baseline config with the self-session server when AIR wrote none" do
    # A skills-only session takes the prepare! branch but AIR writes no config.
    # post_process! must synthesize one and inject the self-session server rather
    # than leaving the session with no Zimmer tools (mirrors the Claude processor).
    @session.update!(mcp_servers: [], catalog_skills: [ "wait-for-ci" ], metadata: { "agent_root_key" => "agent-orchestrator" })

    processor = build_processor
    processor.post_process!

    assert @mock_fs.exists?(config_file_path),
      "post_process! should synthesize the Codex config when AIR wrote none"
    self_server = read_config.dig("mcp_servers", "agent-orchestrator-staging-self-session")
    assert_not_nil self_server, "Self-session Zimmer server should be injected into the synthesized config"
    assert_equal "self_session", self_server.dig("env", "TOOL_GROUPS")
    assert_equal [ "agent-orchestrator-staging-self-session" ], processor.injected_mcp_servers
  end

  test "post_process! injects the subagent Zimmer server when AIR wrote no Codex config for a subagent-roots root" do
    # Secondary defect, Codex flavor: a subagent-roots root with skills (prepare!
    # branch) but no explicit MCP servers gets no config from AIR. The subagent
    # spawning server must still be injected — not gated on an AIR-produced file.
    @session.update!(
      mcp_servers: [],
      catalog_skills: [ "wait-for-ci" ],
      metadata: { "agent_root_key" => "catalog-management" }
    )

    processor = build_processor
    processor.post_process!

    assert @mock_fs.exists?(config_file_path)
    ao_server = read_config.dig("mcp_servers", "agent-orchestrator")
    assert_not_nil ao_server,
      "subagent-spawning agent-orchestrator server must be injected even without an AIR-produced config"
    assert_includes ao_server.dig("env", "ALLOWED_AGENT_ROOTS"), "catalog-mgmt-research"
    assert_equal [ "agent-orchestrator" ], processor.injected_mcp_servers
  end

  test "ensure_baseline! creates .codex/config.toml with the self-session server when none exists" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-key"
    @session.update!(mcp_servers: [])

    refute @mock_fs.exists?(config_file_path)

    build_processor.ensure_baseline!

    assert @mock_fs.exists?(config_file_path),
      "ensure_baseline! must create the Codex config in its .codex/ subdirectory"
    self_server = read_config.dig("mcp_servers", "agent-orchestrator-staging-self-session")
    assert_not_nil self_server, "ensure_baseline! should inject the staging-flavored self-session entry"
    assert_equal "self_session", self_server.dig("env", "TOOL_GROUPS")
    assert_equal "http://localhost:3000", self_server.dig("env", "AGENT_ORCHESTRATOR_BASE_URL")
    assert_equal "local-key", self_server.dig("env", "AGENT_ORCHESTRATOR_API_KEY")
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
  end

  # ---------------------------------------------------------------------------
  # Golden file — byte-for-byte stability of the written .codex/config.toml
  # ---------------------------------------------------------------------------
  # Locks in the exact serialized TOML for a representative config so any future
  # change to the post-processor or the TOML serializer cannot silently alter
  # the bytes Zimmer writes. The input includes a Zimmer server with TOOL_GROUPS blank
  # so self-session injection is deduped away — this keeps the output
  # independent of the runtime catalog and fully deterministic. It exercises all
  # three Codex-specific paths: env retargeting, env_vars secret inlining (with
  # retained host-env forwarding), env_http_headers secret inlining, and the npx
  # --prefix /tmp rewrite.
  test "post_process! produces byte-for-byte stable .codex/config.toml (golden file)" do
    ENV["AGENT_ORCHESTRATOR_LOCAL_API_KEY"] = "local-key"
    stub_secrets("ACME_API_KEY" => "sk-acme-123", "ACME_TOKEN" => "tok-acme-xyz")

    write_config(
      "agent-orchestrator-prod" => {
        "command" => "npx",
        "args" => [ "-y", "agent-orchestrator-mcp-server@latest" ],
        "env" => {
          "AGENT_ORCHESTRATOR_BASE_URL" => "https://zimmer.example.com",
          "AGENT_ORCHESTRATOR_API_KEY" => "prod-key"
        }
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
      [mcp_servers.agent-orchestrator-prod]
      args = ["-y", "--prefix", "/tmp", "agent-orchestrator-mcp-server@latest"]
      command = "npx"
      [mcp_servers.agent-orchestrator-prod.env]
      AGENT_ORCHESTRATOR_API_KEY = "local-key"
      AGENT_ORCHESTRATOR_BASE_URL = "http://localhost:3000"
    TOML

    assert_equal expected, @mock_fs.read(config_file_path),
      "Written .codex/config.toml must match the golden serialization byte-for-byte"
  ensure
    ENV.delete("AGENT_ORCHESTRATOR_LOCAL_API_KEY")
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
