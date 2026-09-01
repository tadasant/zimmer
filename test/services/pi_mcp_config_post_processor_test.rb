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
