# frozen_string_literal: true

require "test_helper"

# Tests for PiMcpConfigPostProcessor — the one runtime post-processor that has to
# WRITE the server table rather than merely adjust it.
#
# `@pulsemcp/air-adapter-pi` is skills-only and writes no MCP config at all, so
# without the seeding these tests cover, a Pi session would start with none of
# the servers it was configured with and nobody would notice until a tool call
# failed.
class PiMcpConfigPostProcessorTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:active_session)
    @session.update!(
      mcp_servers: [ "playwright-custom" ],
      metadata: { "agent_root_key" => "agent-orchestrator" }
    )
    @working_dir = Dir.mktmpdir("pi-mcp-config")
    @mock_fs = MockFileSystemAdapter.new
    ENV["ZIMMER_LOCAL_API_KEY"] ||= "local-test-key"
  end

  teardown do
    FileUtils.remove_entry(@working_dir) if @working_dir && File.exist?(@working_dir)
  end

  test "writes .mcp.json into the working directory" do
    process!

    assert @mock_fs.exists?(config_path), "expected #{config_path} to be written"
    assert_kind_of Hash, config["mcpServers"]
  end

  # The whole reason this class exists: AIR wrote nothing, so the session's
  # configured servers have to be seeded from Zimmer's own catalog.
  test "seeds the session's configured MCP servers even though AIR wrote no config" do
    process!

    entry = config.dig("mcpServers", "playwright-custom")
    assert entry, "expected the configured server to be seeded: #{config.inspect}"
    assert_equal "stdio", entry["type"]
    assert entry["command"].present?
  end

  test "the seeded entry matches the catalog entry it came from" do
    server = ServersConfig.find("playwright-custom")
    process!

    entry = config.dig("mcpServers", "playwright-custom")
    assert_equal server.command, entry["command"]
    assert_equal server.args, entry["args"] if server.args.present?
  end

  # Auto-injection still has to happen on top of the seeding — a Pi session with
  # no self-session server cannot archive itself.
  test "still auto-injects the Zimmer self-session server" do
    process!

    assert config["mcpServers"].key?("zimmer-self-session"),
      "expected the self-session server to be injected: #{config['mcpServers'].keys.inspect}"
  end

  test "an entry AIR already wrote is not overwritten by the catalog seed" do
    @mock_fs.write(config_path, JSON.generate(
      "mcpServers" => { "playwright-custom" => { "type" => "stdio", "command" => "local-override" } }
    ))

    process!

    assert_equal "local-override", config.dig("mcpServers", "playwright-custom", "command")
  end

  # A configured server the catalog no longer knows must degrade one tool, not
  # brick the session's whole startup. This is catalog DRIFT — the id was valid
  # when the session was created and the entry was removed afterwards — so it is
  # stubbed rather than persisted: Session validates mcp_servers against the live
  # catalog and would refuse to store an id the catalog has already dropped.
  test "an unknown server id is skipped rather than raised on" do
    @session.define_singleton_method(:user_selected_mcp_servers) do
      [ "playwright-custom", "no-such-server-anywhere" ]
    end

    assert_nothing_raised { process! }

    assert config["mcpServers"].key?("playwright-custom")
    assert_not config["mcpServers"].key?("no-such-server-anywhere")
  end

  test "a session with no configured servers still gets the baseline injection" do
    @session.update!(mcp_servers: [])

    process!

    assert config["mcpServers"].key?("zimmer-self-session")
  end

  test "ensure_baseline! writes a usable config for a session with nothing configured" do
    @session.update!(mcp_servers: [])

    processor.ensure_baseline!

    assert @mock_fs.exists?(config_path)
    assert config["mcpServers"].key?("zimmer-self-session")
  end

  test "serializes as pretty JSON so the file is readable in a clone" do
    process!

    raw = @mock_fs.read(config_path)
    assert_includes raw, "\n  ", "expected pretty-printed JSON, got: #{raw[0, 80]}"
  end

  # ---------------------------------------------------------------------------
  # MCP startup timeout
  #
  # Pi's MCP client is the pi-mcp-adapter extension, whose only per-entry budget
  # is `requestTimeoutMs` — measured at 60,000ms by default against the pinned
  # 2.32.1, which a cold clone's npm download can eat into. See
  # PiMcpConfigPostProcessor#apply_startup_timeouts!.
  # ---------------------------------------------------------------------------

  test "every seeded stdio server gets the shared MCP startup budget" do
    process!

    assert_equal McpStartupTimeout::MILLISECONDS,
      config.dig("mcpServers", "playwright-custom", "requestTimeoutMs")
  end

  test "a non-npx stdio server gets the same budget" do
    @mock_fs.write(config_path, JSON.generate(
      "mcpServers" => { "not-npx" => { "type" => "stdio", "command" => "/usr/local/bin/thing" } }
    ))

    process!

    assert_equal McpStartupTimeout::MILLISECONDS,
      config.dig("mcpServers", "not-npx", "requestTimeoutMs")
  end

  test "an http server is not given a startup budget" do
    @mock_fs.write(config_path, JSON.generate(
      "mcpServers" => { "acme-http" => { "type" => "http", "url" => "https://acme.example.com/mcp" } }
    ))

    process!

    servers = config["mcpServers"]
    assert_nil servers.dig("acme-http", "requestTimeoutMs"),
      "an http entry reaches an already-running server and has no cold start to absorb"
    assert_nil servers.dig("zimmer-self-session", "requestTimeoutMs"),
      "the auto-injected Zimmer entries are http and must not be given one either"
  end

  test "an entry that already names its own request timeout keeps it" do
    @mock_fs.write(config_path, JSON.generate(
      "mcpServers" => {
        "explicit" => { "type" => "stdio", "command" => "node", "requestTimeoutMs" => 9_000 }
      }
    ))

    process!

    assert_equal 9_000, config.dig("mcpServers", "explicit", "requestTimeoutMs")
  end

  # The adapter reads `<= 0` as "use the SDK default", so preserving a zero is
  # preserving an explicit opt-out rather than writing a broken value.
  test "an entry that opts out with a zero request timeout keeps the zero" do
    @mock_fs.write(config_path, JSON.generate(
      "mcpServers" => {
        "opted-out" => { "type" => "stdio", "command" => "node", "requestTimeoutMs" => 0 }
      }
    ))

    process!

    assert_equal 0, config.dig("mcpServers", "opted-out", "requestTimeoutMs")
  end

  # ensure_baseline! runs for a session with nothing configured, but it parses
  # whatever `.mcp.json` is already on the clone — and a session that HAD MCP
  # servers and no longer does (a follow-up, an unarchive, a fork) reaches it
  # with the previous run's stdio entries still in that file.
  #
  # It covers that only when something is injected: ensure_baseline! returns
  # early on `injected_mcp_servers.empty?`, so a leftover file that ALREADY
  # carries a full-surface Zimmer entry skips this step along with secret
  # resolution and npx pinning. That early return predates this budget and is
  # shared with Codex; the case here is the one where the self-session server is
  # injected, which is what a leftover stdio-only file produces.
  test "ensure_baseline! gives a stdio server already on the clone the budget" do
    @session.update!(mcp_servers: [])
    @mock_fs.write(config_path, JSON.generate(
      "mcpServers" => { "leftover" => { "type" => "stdio", "command" => "node" } }
    ))

    processor.ensure_baseline!

    assert_equal McpStartupTimeout::MILLISECONDS,
      config.dig("mcpServers", "leftover", "requestTimeoutMs")
  end

  # One budget, three spellings. A change to Claude's millisecond constant that
  # did not reach Pi would leave the third runtime on its client's own default.
  test "Pi's budget is the same one Claude gets from MCP_TIMEOUT" do
    process!

    assert_equal ClaudeSpawnEnv::MCP_TIMEOUT_MS,
      config.dig("mcpServers", "playwright-custom", "requestTimeoutMs")
  end

  private

  def processor
    @processor ||= PiMcpConfigPostProcessor.new(
      session: @session,
      working_directory: @working_dir,
      file_system: @mock_fs
    )
  end

  def process!
    processor.post_process!
  end

  def config_path
    File.join(@working_dir, ".mcp.json")
  end

  def config
    JSON.parse(@mock_fs.read(config_path))
  end
end
