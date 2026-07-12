# frozen_string_literal: true

require "test_helper"

class DeploymentInfoServiceTest < ActiveSupport::TestCase
  test "info returns hash with expected keys" do
    info = DeploymentInfoService.info

    assert info.is_a?(Hash)
    assert_includes info.keys, :git
    assert_includes info.keys, :environment
    assert_includes info.keys, :mcp_config
    assert_includes info.keys, :server_count
    assert_includes info.keys, :agent_roots_config
    assert_includes info.keys, :agent_roots_count
    assert_includes info.keys, :skills_config
    assert_includes info.keys, :skills_count
  end

  test "server_count returns correct count" do
    info = DeploymentInfoService.info

    assert_equal ServersConfig.names.count, info[:server_count]
  end

  # Agent roots config tests
  test "agent_roots_config returns hash" do
    config = DeploymentInfoService.agent_roots_config

    assert config.is_a?(Hash)
  end

  test "agent_roots_count returns correct count" do
    info = DeploymentInfoService.info

    assert_equal AgentRootsConfig.names.count, info[:agent_roots_count]
  end

  test "agent_roots_config does not modify original config" do
    original = AgentRootsConfig.config
    original_json = original.to_json

    DeploymentInfoService.agent_roots_config

    assert_equal original_json, AgentRootsConfig.config.to_json
  end

  # Skills config tests
  test "skills_config returns hash" do
    config = DeploymentInfoService.skills_config

    assert config.is_a?(Hash)
  end

  test "skills_count returns correct count" do
    info = DeploymentInfoService.info

    assert_equal SkillsConfig.names.count, info[:skills_count]
  end

  test "skills_config does not modify original config" do
    original = SkillsConfig.config
    original_json = original.to_json

    DeploymentInfoService.skills_config

    assert_equal original_json, SkillsConfig.config.to_json
  end

  # Git information tests
  test "git_info returns hash with expected keys" do
    git_info = DeploymentInfoService.git_info

    assert git_info.is_a?(Hash)
    assert_includes git_info.keys, :commit_sha
    assert_includes git_info.keys, :commit_short
    assert_includes git_info.keys, :branch
    assert_includes git_info.keys, :commit_date
  end

  test "git_info commit_sha is a string" do
    git_info = DeploymentInfoService.git_info

    assert git_info[:commit_sha].is_a?(String)
    # Should be either 40-char SHA or "unknown"
    assert(git_info[:commit_sha] == "unknown" || git_info[:commit_sha].match?(/\A[a-f0-9]{40}\z/))
  end

  test "git_info commit_short is 7 characters or unknown" do
    git_info = DeploymentInfoService.git_info

    assert git_info[:commit_short].is_a?(String)
    assert(git_info[:commit_short] == "unknown" || git_info[:commit_short].length == 7)
  end

  test "git_info branch is a string" do
    git_info = DeploymentInfoService.git_info

    assert git_info[:branch].is_a?(String)
    assert git_info[:branch].present? || git_info[:branch] == "unknown"
  end

  # Environment information tests
  test "environment_info returns hash with expected keys" do
    env_info = DeploymentInfoService.environment_info

    assert env_info.is_a?(Hash)
    assert_includes env_info.keys, :rails_env
    assert_includes env_info.keys, :ruby_version
    assert_includes env_info.keys, :rails_version
  end

  test "environment_info returns correct rails_env" do
    env_info = DeploymentInfoService.environment_info

    assert_equal Rails.env, env_info[:rails_env]
  end

  test "environment_info returns correct ruby_version" do
    env_info = DeploymentInfoService.environment_info

    assert_equal RUBY_VERSION, env_info[:ruby_version]
  end

  test "environment_info returns correct rails_version" do
    env_info = DeploymentInfoService.environment_info

    assert_equal Rails::VERSION::STRING, env_info[:rails_version]
  end

  # MCP config tests
  test "mcp_config_with_redacted_secrets returns hash" do
    mcp_config = DeploymentInfoService.mcp_config_with_redacted_secrets

    assert mcp_config.is_a?(Hash)
  end

  test "mcp_config keys are server names only" do
    # AirCatalogService strips $-prefixed metadata when merging entries from
    # multiple source files (different sources may declare different $schema
    # values). The deployment info page now shows merged server entries only.
    mcp_config = DeploymentInfoService.mcp_config_with_redacted_secrets

    refute_includes mcp_config.keys, "$schema"
    assert mcp_config.keys.all? { |k| !k.to_s.start_with?("$") }
  end

  test "mcp_config redacts header values containing environment variables" do
    mcp_config = DeploymentInfoService.mcp_config_with_redacted_secrets

    # Zimmer's own MCP entries carry an interpolated credential header
    # (X-API-Key = ${ZIMMER_PROD_API_KEY}).
    zimmer_server = mcp_config["zimmer-self-session"]
    assert_not_nil zimmer_server, "zimmer-self-session server should exist"

    # Check that header values with ${VAR} pattern are redacted
    api_key_value = zimmer_server.dig("headers", "X-API-Key")
    assert_not_nil api_key_value, "X-API-Key header should exist"
    assert_equal "[REDACTED - contains env var]", api_key_value
  end

  test "mcp_config redacts values for sensitive key names" do
    mcp_config = DeploymentInfoService.mcp_config_with_redacted_secrets

    # Check servers with token/key/password in env key names
    mcp_config.each do |key, server_config|
      next if key.start_with?("$")
      next unless server_config.is_a?(Hash) && server_config["env"].is_a?(Hash)

      server_config["env"].each do |env_key, value|
        next unless value.is_a?(String)

        # If key contains sensitive patterns, value should be redacted
        is_sensitive_key = %w[token password secret _key api_key private_key credential bearer].any? do |pattern|
          env_key.downcase.include?(pattern)
        end

        if is_sensitive_key
          assert_match(/\[REDACTED.*\]/, value, "#{key}[env][#{env_key}] should be redacted")
        end
      end
    end
  end

  test "mcp_config preserves non-sensitive values" do
    mcp_config = DeploymentInfoService.mcp_config_with_redacted_secrets

    # playwright-custom has non-sensitive env values like STEALTH_MODE
    playwright_server = mcp_config["playwright-custom"]
    assert_not_nil playwright_server, "playwright-custom server should exist"

    # These should be preserved since they don't contain interpolations or sensitive patterns
    stealth_mode = playwright_server.dig("env", "STEALTH_MODE")
    headless = playwright_server.dig("env", "HEADLESS")

    # These are plain values, not interpolations, so they should be preserved
    assert_equal "false", stealth_mode, "STEALTH_MODE should be preserved"
    assert_equal "true", headless, "HEADLESS should be preserved"
  end

  test "mcp_config preserves server structure" do
    mcp_config = DeploymentInfoService.mcp_config_with_redacted_secrets

    # Check a server still has its basic structure
    playwright_server = mcp_config["playwright-custom"]
    assert_not_nil playwright_server

    assert_includes playwright_server.keys, "title"
    assert_includes playwright_server.keys, "description"
    assert_includes playwright_server.keys, "type"
    assert_includes playwright_server.keys, "command"
  end

  test "mcp_config does not modify original config" do
    # Get original config
    original = ServersConfig.config
    original_json = original.to_json

    # Call redaction method
    DeploymentInfoService.mcp_config_with_redacted_secrets

    # Verify original is unchanged
    assert_equal original_json, ServersConfig.config.to_json
  end

  # URL redaction tests
  test "mcp_config redacts URLs containing environment variables" do
    mcp_config = DeploymentInfoService.mcp_config_with_redacted_secrets

    # Find a server with URL containing env vars
    mcp_config.each do |key, server_config|
      next if key.start_with?("$")
      next unless server_config.is_a?(Hash) && server_config["url"].is_a?(String)

      url = server_config["url"]
      # URLs should not contain ${VAR} patterns
      assert_no_match(/\$\{[A-Z_][A-Z0-9_]*\}/, url, "#{key}[url] should have env vars redacted")
    end
  end

  # Args redaction tests
  test "mcp_config redacts args containing environment variables" do
    mcp_config = DeploymentInfoService.mcp_config_with_redacted_secrets

    # Find servers with args containing env vars
    mcp_config.each do |key, server_config|
      next if key.start_with?("$")
      next unless server_config.is_a?(Hash) && server_config["args"].is_a?(Array)

      server_config["args"].each_with_index do |arg, idx|
        next unless arg.is_a?(String)

        # Args should not contain ${VAR} patterns
        assert_no_match(/\$\{[A-Z_][A-Z0-9_]*\}/, arg, "#{key}[args][#{idx}] should have env vars redacted")
      end
    end
  end

  # Test using environment variables
  test "git_commit_sha uses GIT_COMMIT_SHA env var when set" do
    original_env = ENV["GIT_COMMIT_SHA"]
    begin
      ENV["GIT_COMMIT_SHA"] = "abc123def456789"

      # Force reload of cached values
      DeploymentInfoService.instance_variable_set(:@git_commit_sha, nil)

      git_info = DeploymentInfoService.git_info
      assert_equal "abc123def456789", git_info[:commit_sha]
    ensure
      ENV["GIT_COMMIT_SHA"] = original_env
      DeploymentInfoService.instance_variable_set(:@git_commit_sha, nil)
    end
  end

  test "git_branch uses GIT_BRANCH env var when set" do
    original_env = ENV["GIT_BRANCH"]
    begin
      ENV["GIT_BRANCH"] = "feature/test-branch"

      # Force reload of cached values
      DeploymentInfoService.instance_variable_set(:@git_branch, nil)

      git_info = DeploymentInfoService.git_info
      assert_equal "feature/test-branch", git_info[:branch]
    ensure
      ENV["GIT_BRANCH"] = original_env
      DeploymentInfoService.instance_variable_set(:@git_branch, nil)
    end
  end

  # Test URL credentials detection
  test "url_credentials_pattern detects embedded credentials" do
    # Test the pattern directly
    pattern = DeploymentInfoService::URL_CREDENTIALS_PATTERN

    # Should match URLs with credentials
    assert_match pattern, "postgresql://user:password@host/db"
    assert_match pattern, "https://admin:secret123@example.com/api"
    assert_match pattern, "redis://default:mypassword@localhost:6379"

    # Should not match URLs without credentials
    assert_no_match pattern, "https://example.com/api"
    assert_no_match pattern, "postgresql://host/db"
    assert_no_match pattern, "redis://localhost:6379"
  end

  # Test sensitive value pattern detection
  test "sensitive_value_patterns detect secrets in values" do
    patterns = DeploymentInfoService::SENSITIVE_VALUE_PATTERNS

    # Create a test method to check if any pattern matches
    matches_sensitive = ->(value) { patterns.any? { |p| value.downcase.include?(p) } }

    # Should match values containing sensitive patterns
    assert matches_sensitive.call("--password=secret123")
    assert matches_sensitive.call("api_key=abc123")
    assert matches_sensitive.call("token=xyz")
    assert matches_sensitive.call("--apikey=test")

    # Should not match normal values
    assert_not matches_sensitive.call("--url=http://example.com")
    assert_not matches_sensitive.call("--verbose")
    assert_not matches_sensitive.call("some-arg-value")
  end
end
