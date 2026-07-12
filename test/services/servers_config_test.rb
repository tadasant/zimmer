require "test_helper"

class ServersConfigTest < ActiveSupport::TestCase
  # Test loading servers
  test "should load all servers from config" do
    servers = ServersConfig.all
    assert servers.is_a?(Array)
    assert servers.all? { |s| s.is_a?(ServersConfig::Server) }
  end

  test "should have expected servers from config" do
    server_names = ServersConfig.names

    # Spot-check some key server names from mcp-servers/mcp.json in the catalog
    # We don't assert on total count as it changes frequently when adding servers
    assert_includes server_names, "playwright-custom"
    assert_includes server_names, "context7"
    assert_includes server_names, "linear"
    assert_includes server_names, "twist-wolfbot"
    assert_includes server_names, "figma"
    assert_includes server_names, "tally"
    assert_includes server_names, "notion"
    assert_includes server_names, "zimmer"
    assert_includes server_names, "zimmer-sessions"
    assert_includes server_names, "zimmer-self-session"
  end

  # Test finding servers
  test "should find server by name" do
    server = ServersConfig.find("playwright-custom")
    assert_not_nil server
    assert_equal "playwright-custom", server.name
  end

  test "should return nil for non-existent server" do
    server = ServersConfig.find("nonexistent")
    assert_nil server
  end

  test "should raise error with find! for non-existent server" do
    assert_raises(ServersConfig::ServerNotFoundError) do
      ServersConfig.find!("nonexistent")
    end
  end

  test "should include server name in error message" do
    error = assert_raises(ServersConfig::ServerNotFoundError) do
      ServersConfig.find!("missing_server")
    end
    assert_includes error.message, "missing_server"
  end

  # Test server existence
  test "should return true for existing server" do
    assert ServersConfig.exists?("playwright-custom")
    assert ServersConfig.exists?("context7")
    assert ServersConfig.exists?("linear")
    assert ServersConfig.exists?("tally")
    assert ServersConfig.exists?("twist-wolfbot")
  end

  test "should return false for non-existent server" do
    assert_not ServersConfig.exists?("nonexistent")
  end

  # Test server names
  test "should return array of server names" do
    names = ServersConfig.names
    assert names.is_a?(Array)
    assert names.all? { |n| n.is_a?(String) }
  end

  # Test reload functionality
  test "should reload configuration" do
    # Get initial servers
    initial_servers = ServersConfig.all

    # Reload
    reloaded_servers = ServersConfig.reload!

    # Should return same data (since config file hasn't changed)
    assert_equal initial_servers.map(&:name), reloaded_servers.map(&:name)
  end

  # Test Server object - basic attributes
  test "server should have name attribute" do
    server = ServersConfig.find("playwright-custom")
    assert_equal "playwright-custom", server.name
  end

  test "server should have title attribute as display name" do
    server = ServersConfig.find("playwright-custom")
    assert_equal "Playwright Custom", server.title
  end

  test "server should have description attribute" do
    server = ServersConfig.find("playwright-custom")
    assert_includes server.description, "Playwright MCP server"
  end

  test "server should have type attribute" do
    server = ServersConfig.find("playwright-custom")
    assert_equal "stdio", server.type
  end

  test "server should have command attribute" do
    server = ServersConfig.find("playwright-custom")
    assert_equal "npx", server.command
  end

  test "server should have args array" do
    server = ServersConfig.find("playwright-custom")
    assert server.args.is_a?(Array)
    assert_includes server.args, "-y"
  end

  test "server should have env hash" do
    server = ServersConfig.find("playwright-custom")
    assert server.env.is_a?(Hash)
    assert server.env.key?("STEALTH_MODE")
  end

  # Test stdio vs remote detection
  test "should detect stdio servers" do
    server = ServersConfig.find("playwright-custom")
    assert server.stdio?
    refute server.remote?
  end

  test "should detect playwright-custom as stdio" do
    server = ServersConfig.find("playwright-custom")
    assert server.stdio?
    refute server.remote?
  end

  # Test environment variable detection. Zimmer's own MCP entries are remote
  # (streamable-http) and carry their API key in a header, so the interpolation
  # they exercise is header interpolation, not env.
  test "should identify required header variables" do
    server = ServersConfig.find("zimmer-self-session")
    required_headers = server.required_headers

    assert required_headers.is_a?(Array)
    assert_includes required_headers, "ZIMMER_PROD_API_KEY"
  end

  test "should identify optional header variables" do
    server = ServersConfig.find("zimmer-self-session")
    optional_headers = server.optional_headers

    # Only ZIMMER_PROD_API_KEY is interpolated (required); no ${VAR:-default} optionals.
    assert optional_headers.is_a?(Array)
    assert_empty optional_headers
  end

  test "a stdio server with hardcoded env has no interpolated vars" do
    server = ServersConfig.find("playwright-custom")

    assert_empty server.required_env_vars
    assert_empty server.all_env_vars
  end

  # Test to_h method
  test "server should convert to hash" do
    server = ServersConfig.find("playwright-custom")
    hash = server.to_h

    assert hash.is_a?(Hash)
    assert_equal "playwright-custom", hash[:name]
    assert_equal "Playwright Custom", hash[:title]
    assert_includes hash[:description], "Playwright MCP server"
    assert_equal "stdio", hash[:type]
    assert_equal "npx", hash[:command]
    assert hash.key?(:args)
    assert hash.key?(:env)
    assert_equal false, hash[:remote?]
  end

  # Test to_json method
  test "server should convert to json" do
    server = ServersConfig.find("playwright-custom")
    json = server.to_json

    assert json.is_a?(String)
    parsed = JSON.parse(json)
    assert_equal "playwright-custom", parsed["name"]
    assert_equal "Playwright Custom", parsed["title"]
    assert_includes parsed["description"], "Playwright MCP server"
    assert_equal "stdio", parsed["type"]
  end

  # Test raw config access
  test "should access raw config" do
    config = ServersConfig.config
    assert config.is_a?(Hash)
    assert config.key?("playwright-custom")
    assert config.key?("context7")
    assert config.key?("linear")
    assert config.key?("tally")
  end

  # TTL/cache invalidation lives in AirCatalogService and is exercised in
  # AirCatalogServiceTest. ServersConfig only delegates.
  test "reload! re-reads from AirCatalogService" do
    ServersConfig.reload!
    initial_servers = ServersConfig.all
    assert initial_servers.any?, "Expected servers to be loaded"

    reloaded_servers = ServersConfig.reload!
    assert_equal initial_servers.map(&:name), reloaded_servers.map(&:name)
  end

  # Test error handling
  test "should have ConfigurationError exception class" do
    # Verify custom error class exists
    assert_kind_of Class, ServersConfig::ConfigurationError
    assert ServersConfig::ConfigurationError < StandardError
  end

  test "should have ServerNotFoundError exception class" do
    # Verify custom error class exists
    assert_kind_of Class, ServersConfig::ServerNotFoundError
    assert ServersConfig::ServerNotFoundError < StandardError
  end

  # Test configuration structure
  test "npx server should have proper structure" do
    server = ServersConfig.find("playwright-custom")

    assert_equal "npx", server.command
    assert_includes server.args, "-y"
    assert server.args.any? { |arg| arg.start_with?("playwright-stealth-mcp-server@") },
      "Expected args to include a playwright-stealth-mcp-server@ package"
  end

  test "should handle servers with no headers" do
    server = ServersConfig.find("playwright-custom")

    # Should not raise error
    assert server.required_headers.is_a?(Array)
    assert server.optional_headers.is_a?(Array)
    assert_empty server.required_headers
    assert_empty server.optional_headers
  end

  # Test interpolation pattern detection
  test "should detect required var without default" do
    server = ServersConfig.find("zimmer-self-session")

    # The config uses ${ZIMMER_PROD_API_KEY} interpolation in the
    # X-API-Key header.
    assert_includes server.required_headers, "ZIMMER_PROD_API_KEY"
  end

  test "should return empty optional vars when all are hardcoded" do
    server = ServersConfig.find("zimmer-self-session")

    # All interpolated vars are required; nothing uses a ${VAR:-default} optional form.
    assert_empty server.optional_headers
  end

  test "Zimmer's own MCP entries are remote and scoped by query string" do
    full = ServersConfig.find("zimmer")
    sessions = ServersConfig.find("zimmer-sessions")
    self_session = ServersConfig.find("zimmer-self-session")

    assert full.remote?
    assert_equal "streamable-http", full.type
    assert full.url.end_with?("/mcp"), "the full-surface entry carries no tool_groups scoping"
    assert_includes sessions.url, "tool_groups=sessions"
    assert_includes self_session.url, "tool_groups=self_session"
    assert_equal "${ZIMMER_PROD_API_KEY}", self_session.headers["X-API-Key"]
  end
end
