# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The prepare-path step (RuntimeConfigPostProcessor#inject_brokered_credentials!)
# for all three runtimes: an opted-in entry gets this turn's child token where
# the static bearer went, or is left out of the config; an entry that does not
# opt in — and every entry when none does — is written exactly as before.
class BrokeredRuntimeConfigTest < ActiveSupport::TestCase
  include TokenBrokerTestHelpers

  STATIC_KEY = "static-strad-key-0123456789abcdef"

  setup do
    turn_token_broker_on
    @strad = FakeStrad.new
    client = @strad.client
    TokenBroker::Client.stubs(:new).returns(client)
    @session = sessions(:active_session)
    @session.update_columns(mcp_servers: %w[image-diff granola], metadata: { "agent_root_key" => "general-agent" })
    @working_dir = Dir.mktmpdir("brokered-config")
    @mock_fs = MockFileSystemAdapter.new
    @saved_env = ENV.to_hash.slice("STRAD_API_KEY", "ZIMMER_LOCAL_API_KEY")
    ENV["STRAD_API_KEY"] = STATIC_KEY
    ENV["ZIMMER_LOCAL_API_KEY"] ||= "local-test-key"
    SecretProviders.reset!
  end

  teardown do
    FileUtils.remove_entry(@working_dir) if File.exist?(@working_dir)
    ENV.delete("STRAD_API_KEY")
    @saved_env.each { |k, v| ENV[k] = v }
    SecretProviders.reset!
  end

  # --- Claude Code (.mcp.json) -------------------------------------------

  test "claude: with no entry opted in, the config is exactly today's" do
    stub_mcp_catalog("image-diff" => static_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    write_json_config(claude_entries)

    processor = claude_processor(mint: true)
    processor.post_process!

    servers = json_servers
    assert_equal "Bearer #{STATIC_KEY}", servers.dig("image-diff", "headers", "Authorization")
    assert_equal "Bearer #{STATIC_KEY}", servers.dig("granola", "headers", "Authorization")
    refute processor.brokered_token_result.any?
    assert_empty @strad.requests
    assert_equal 0, McpBrokeredToken.count
  end

  test "claude: a brokered entry carries the child token, a static one beside it keeps the static key" do
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    write_json_config(claude_entries)

    with_oauth_client_identity do
      @strad.create_grant!
      claude_processor(mint: true).post_process!
    end

    servers = json_servers
    child = McpBrokeredToken.sole.token
    assert_equal({ "Authorization" => "Bearer #{child}" }, servers.dig("image-diff", "headers").slice("Authorization"))
    assert_equal 1, servers.dig("image-diff", "headers").keys.count { |k| k.casecmp?("authorization") }
    assert_equal "Bearer #{STATIC_KEY}", servers.dig("granola", "headers", "Authorization")
    refute_includes JSON.generate(servers["image-diff"]), STATIC_KEY
  end

  test "claude: an AIR-resolved static header under any casing is replaced, not kept alongside" do
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"))
    write_json_config("image-diff" => { "type" => "http", "url" => "#{FakeStrad::ORIGIN}/mcp?servers=image-diff",
                                        "headers" => { "authorization" => "Bearer #{STATIC_KEY}" } })

    with_oauth_client_identity do
      @strad.create_grant!
      claude_processor(mint: true).post_process!
    end

    refute_includes JSON.generate(json_servers), STATIC_KEY
  end

  test "claude: when minting fails the entry is left out and the cause is reported, never the static key" do
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    write_json_config(claude_entries)

    processor = nil
    with_oauth_client_identity do
      processor = claude_processor(mint: true)
      processor.post_process! # no grant exists
    end

    servers = json_servers
    refute servers.key?("image-diff")
    assert servers.key?("granola")
    assert_match(/no token broker grant exists/, processor.brokered_token_result.failures["image-diff"])
  end

  test "claude: outside a turn start a brokered entry is left out and nothing is minted" do
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    write_json_config(claude_entries)

    with_oauth_client_identity do
      @strad.create_grant!
      claude_processor(mint: false).post_process!
    end

    refute json_servers.key?("image-diff")
    assert_empty @strad.requests
  end

  test "claude: a broker that raises costs only the brokered entries" do
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    write_json_config(claude_entries)
    TokenBroker.stubs(:mint_for_session).raises(ActiveRecord::ConnectionTimeoutError, "pool exhausted")

    processor = claude_processor(mint: true)
    processor.post_process!

    refute json_servers.key?("image-diff")
    assert json_servers.key?("granola")
    assert_equal "the token broker raised ActiveRecord::ConnectionTimeoutError", processor.brokered_token_result.failures["image-diff"]
  end

  # --- Codex (.codex/config.toml) -----------------------------------------

  test "codex: with no entry opted in, bearer_token_env_var is left exactly as AIR wrote it" do
    @session.update_columns(agent_runtime: "codex")
    stub_mcp_catalog("image-diff" => static_strad_entry("image-diff"))
    write_toml_config("image-diff" => codex_entry("image-diff"))

    codex_processor(mint: true).post_process!

    entry = toml_servers["image-diff"]
    assert_equal "STRAD_API_KEY", entry["bearer_token_env_var"]
    assert_nil entry.dig("http_headers", "Authorization")
  end

  test "codex: a brokered entry drops the env forwarding and carries the child as a literal header" do
    @session.update_columns(agent_runtime: "codex")
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    write_toml_config("image-diff" => codex_entry("image-diff").merge("env_http_headers" => { "Authorization" => "STRAD_API_KEY" }),
                      "granola" => codex_entry("granola"))

    with_oauth_client_identity do
      @strad.create_grant!
      codex_processor(mint: true).post_process!
    end

    entry = toml_servers["image-diff"]
    assert_nil entry["bearer_token_env_var"]
    assert_nil entry["env_http_headers"]
    assert_equal "Bearer #{McpBrokeredToken.sole.token}", entry.dig("http_headers", "Authorization")
    assert_equal "STRAD_API_KEY", toml_servers.dig("granola", "bearer_token_env_var")
  end

  # --- Pi (.mcp.json seeded from the catalog) ------------------------------

  test "pi: with no entry opted in, the seeded entry keeps the static header" do
    @session.update_columns(agent_runtime: "pi")
    stub_mcp_catalog("image-diff" => static_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))

    pi_processor(mint: true).post_process!

    assert_equal "Bearer #{STATIC_KEY}", json_servers.dig("image-diff", "headers", "Authorization")
  end

  test "pi: a brokered entry seeded from the catalog carries the child token" do
    @session.update_columns(agent_runtime: "pi")
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))

    with_oauth_client_identity do
      @strad.create_grant!
      pi_processor(mint: true).post_process!
    end

    assert_equal "Bearer #{McpBrokeredToken.sole.token}", json_servers.dig("image-diff", "headers", "Authorization")
    assert_equal "Bearer #{STATIC_KEY}", json_servers.dig("granola", "headers", "Authorization")
  end

  # --- what else stops reaching a session -------------------------------

  test "a brokered entry's static header variable leaves the session's secret scope" do
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff").merge("env" => { "X" => "${OTHER_VAR}" }))
    assert_equal %w[OTHER_VAR], ServersConfig.find("image-diff").session_variables

    stub_mcp_catalog("image-diff" => static_strad_entry("image-diff"))
    assert_equal %w[STRAD_API_KEY], ServersConfig.find("image-diff").session_variables
  end

  test "the OAuth credential injector never handles a brokered entry" do
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff").except("headers"), "granola" => static_strad_entry("granola"))

    injector = McpOauthCredentialInjector.new(@session, working_directory: @working_dir)
    assert_equal %w[granola], injector.send(:mcp_servers)
    refute McpOauthCredentialInjector.oauth_capable_server?("image-diff")
  end

  private

  def claude_entries
    {
      "image-diff" => { "type" => "http", "url" => "#{FakeStrad::ORIGIN}/mcp?servers=image-diff",
                        "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" } },
      "granola" => { "type" => "http", "url" => "#{FakeStrad::ORIGIN}/mcp?servers=granola",
                     "headers" => { "Authorization" => "Bearer ${STRAD_API_KEY}" } }
    }
  end

  # The shape AIR's Codex adapter writes for `Authorization: Bearer ${VAR}`.
  def codex_entry(slug)
    { "url" => "#{FakeStrad::ORIGIN}/mcp?servers=#{slug}", "bearer_token_env_var" => "STRAD_API_KEY" }
  end

  def claude_processor(mint:) = processor(ClaudeMcpConfigPostProcessor, mint)
  def codex_processor(mint:) = processor(CodexConfigTomlPostProcessor, mint)
  def pi_processor(mint:) = processor(PiMcpConfigPostProcessor, mint)

  def processor(klass, mint)
    klass.new(session: @session, working_directory: @working_dir, file_system: @mock_fs).tap do |p|
      p.mint_brokered_tokens = mint
    end
  end

  def json_path = File.join(@working_dir, ".mcp.json")
  def toml_path = File.join(@working_dir, ".codex", "config.toml")

  def write_json_config(servers) = @mock_fs.write(json_path, JSON.pretty_generate("mcpServers" => servers))
  def json_servers = JSON.parse(@mock_fs.read(json_path))["mcpServers"]

  def write_toml_config(servers) = @mock_fs.write(toml_path, TomlRB.dump("mcp_servers" => servers))
  def toml_servers = TomlRB.parse(@mock_fs.read(toml_path))["mcp_servers"]
end
