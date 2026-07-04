# frozen_string_literal: true

# Service class for collecting deployment information
# Provides details about the current deployment for troubleshooting.
#
# Note: Git information is memoized at the class level to capture the state
# at application boot time, which is intentional for deployment info.
class DeploymentInfoService
  # Pattern to match environment variable interpolations: ${VAR} or ${VAR:-default}
  ENV_VAR_PATTERN = /\$\{[A-Z_][A-Z0-9_]*(?::-[^}]*)?\}/

  # Pattern to detect embedded credentials in URLs (e.g., postgresql://user:pass@host)
  URL_CREDENTIALS_PATTERN = %r{://[^/:@]+:[^/:@]+@}

  # Sensitive patterns to redact in key names (case insensitive)
  SENSITIVE_KEY_PATTERNS = %w[
    password
    secret
    token
    _key
    api_key
    private_key
    credential
    bearer
  ].freeze

  # Sensitive patterns to detect in values (case insensitive)
  SENSITIVE_VALUE_PATTERNS = %w[
    password=
    secret=
    token=
    api_key=
    apikey=
  ].freeze

  class << self
    # Get all deployment information
    # @return [Hash] deployment details
    def info
      {
        git: git_info,
        environment: environment_info,
        mcp_config: mcp_config_with_redacted_secrets,
        server_count: server_count,
        agent_roots_config: agent_roots_config,
        agent_roots_count: agent_roots_count,
        skills_config: skills_config,
        skills_count: skills_count,
        catalog_pins: catalog_pins
      }
    end

    # Per-catalog pin status for the settings UI. For each pinnable catalog
    # declared in air.json, reports the configured pin (if any), the SHA it
    # currently resolves to, and the live HEAD SHA (used by "Pin to current
    # HEAD"). SHAs are nil until the catalog has been fetched into the AIR cache.
    # @return [Array<Hash>]
    def catalog_pins
      pins = CatalogPin.as_map
      AirCatalogService.pinnable_catalogs.map do |catalog|
        pinned_ref = pins[catalog]
        {
          catalog: catalog,
          name: catalog.sub(%r{\Agithub://}, ""),
          pinned_ref: pinned_ref,
          resolved_sha: AirCatalogService.resolved_sha_for(catalog, ref: pinned_ref.presence || "HEAD"),
          head_sha: AirCatalogService.resolved_sha_for(catalog, ref: "HEAD")
        }
      end
    end

    # Get git information
    # @return [Hash] git details
    def git_info
      {
        commit_sha: git_commit_sha,
        commit_short: git_commit_short,
        branch: git_branch,
        commit_date: git_commit_date
      }
    end

    # Get environment information
    # @return [Hash] environment details
    def environment_info
      {
        rails_env: Rails.env,
        ruby_version: RUBY_VERSION,
        rails_version: Rails::VERSION::STRING
      }
    end

    # Get MCP configuration with secrets redacted
    # @return [Hash] mcp.json content with secrets redacted
    def mcp_config_with_redacted_secrets
      config = ServersConfig.config.deep_dup
      redact_secrets_in_config(config)
      config
    end

    # Get count of configured MCP servers
    # @return [Integer] number of servers
    def server_count
      ServersConfig.names.count
    end

    # Get agent roots configuration
    # @return [Hash] roots.json content
    def agent_roots_config
      AgentRootsConfig.config.deep_dup
    end

    # Get count of configured agent roots
    # @return [Integer] number of agent roots
    def agent_roots_count
      AgentRootsConfig.names.count
    end

    # Get skills configuration
    # @return [Hash] skills.json content
    def skills_config
      SkillsConfig.config.deep_dup
    end

    # Get count of configured skills
    # @return [Integer] number of skills
    def skills_count
      SkillsConfig.names.count
    end

    private

    def git_commit_sha
      @git_commit_sha ||= ENV.fetch("GIT_COMMIT_SHA", nil) || read_git_commit_sha
    end

    def git_commit_short
      sha = git_commit_sha
      sha == "unknown" ? sha : sha[0, 7]
    end

    def git_branch
      @git_branch ||= ENV.fetch("GIT_BRANCH", nil) || read_git_branch
    end

    def git_commit_date
      @git_commit_date ||= read_git_commit_date
    end

    def read_git_commit_sha
      `git rev-parse HEAD 2>/dev/null`.strip.presence || "unknown"
    end

    def read_git_branch
      `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip.presence || "unknown"
    end

    def read_git_commit_date
      date_str = `git log -1 --format=%ci 2>/dev/null`.strip
      return nil if date_str.blank?

      Time.zone.parse(date_str).iso8601
    rescue ArgumentError
      nil
    end

    def redact_secrets_in_config(config)
      config.each do |key, value|
        next if key.start_with?("$") # Skip $schema

        redact_server_config(value) if value.is_a?(Hash)
      end
    end

    def redact_server_config(server_config)
      # Redact env values
      if server_config["env"].is_a?(Hash)
        server_config["env"] = redact_hash_values(server_config["env"])
      end

      # Redact headers values
      if server_config["headers"].is_a?(Hash)
        server_config["headers"] = redact_hash_values(server_config["headers"])
      end

      # Redact url if it contains interpolations or embedded credentials
      if server_config["url"].is_a?(String)
        server_config["url"] = redact_url(server_config["url"])
      end

      # Redact args that might contain secrets
      if server_config["args"].is_a?(Array)
        server_config["args"] = server_config["args"].map { |arg| redact_arg(arg) }
      end
    end

    def redact_hash_values(hash)
      hash.to_h { |key, value| [ key, redact_value(value, key) ] }
    end

    def redact_value(value, key)
      return value unless value.is_a?(String)
      return "[REDACTED - contains env var]" if value.match?(ENV_VAR_PATTERN)
      return "[REDACTED]" if sensitive_key?(key)

      value
    end

    def redact_url(url)
      return "[REDACTED - contains env var]" if url.match?(ENV_VAR_PATTERN)
      return "[REDACTED - contains credentials]" if url.match?(URL_CREDENTIALS_PATTERN)

      url
    end

    def redact_arg(arg)
      return arg unless arg.is_a?(String)
      return "[REDACTED - contains env var]" if arg.match?(ENV_VAR_PATTERN)
      return "[REDACTED - contains sensitive value]" if contains_sensitive_value?(arg)

      arg
    end

    def sensitive_key?(key)
      return false unless key.is_a?(String)

      key_lower = key.downcase
      SENSITIVE_KEY_PATTERNS.any? { |pattern| key_lower.include?(pattern) }
    end

    def contains_sensitive_value?(value)
      return false unless value.is_a?(String)

      value_lower = value.downcase
      SENSITIVE_VALUE_PATTERNS.any? { |pattern| value_lower.include?(pattern) }
    end
  end
end
