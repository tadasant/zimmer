# frozen_string_literal: true

# Service class for managing MCP server configurations.
# Reads server entries from AirCatalogService, which discovers them via air.json.
class ServersConfig
  class ServerNotFoundError < StandardError; end
  class ConfigurationError < StandardError; end

  # Environment variable interpolation pattern: ${VAR} or ${VAR:-default}
  ENV_VAR_PATTERN = /\$\{([A-Z_][A-Z0-9_]*)(?::-([^}]*))?\}/

  # Server configuration object
  class Server
    attr_reader :name, :title, :description, :type, :command, :args, :env, :url, :headers, :oauth

    def initialize(name, config)
      @name = name
      @title = config["title"] || name
      @description = config["description"]
      @type = config["type"]
      @command = config["command"]
      @args = config["args"] || []
      @env = config["env"] || {}
      @url = config["url"]
      @headers = config["headers"] || {}
      @oauth = config["oauth"] || {}
    end

    def remote?
      %w[sse streamable-http].include?(type)
    end

    # Statically-configured OAuth client id for this server, taken from the
    # catalog `oauth` block. Present for servers that require a pre-registered
    # OAuth client and expose no usable Dynamic Client Registration endpoint
    # (e.g. Slack). The catalog schema uses camelCase (`clientId`); snake_case is
    # accepted as a tolerant fallback.
    def oauth_client_id
      @oauth["clientId"] || @oauth["client_id"]
    end

    # Statically-configured OAuth client secret, when the pre-registered client
    # is confidential. Public clients (like Slack's) configure only a client id.
    def oauth_client_secret
      @oauth["clientSecret"] || @oauth["client_secret"]
    end

    def stdio?
      type == "stdio"
    end

    def required_env_vars
      env_vars_from_interpolation(with_defaults: false)
    end

    def optional_env_vars
      env_vars_from_interpolation(with_defaults: true)
    end

    def all_env_vars
      required_env_vars + optional_env_vars
    end

    def required_headers
      headers_from_interpolation(with_defaults: false)
    end

    def optional_headers
      headers_from_interpolation(with_defaults: true)
    end

    def to_h
      result = {
        name: name,
        title: title,
        description: description,
        type: type,
        remote?: remote?
      }

      if stdio?
        result.merge!(command: command, args: args, env: env)
      else
        result.merge!(url: url, headers: headers)
      end

      result
    end

    def to_json(*args)
      to_h.to_json(*args)
    end

    private

    def env_vars_from_interpolation(with_defaults:)
      vars = []
      env.each_value do |value|
        extract_interpolations(value, with_defaults: with_defaults).each do |var|
          vars << var
        end
      end
      vars.uniq
    end

    def headers_from_interpolation(with_defaults:)
      vars = []
      headers.each_value do |value|
        extract_interpolations(value, with_defaults: with_defaults).each do |var|
          vars << var
        end
      end
      vars.uniq
    end

    def extract_interpolations(str, with_defaults:)
      return [] unless str.is_a?(String)

      vars = []
      str.scan(ENV_VAR_PATTERN) do |var_name, default_value|
        has_default = !default_value.nil?
        if with_defaults == has_default
          vars << var_name
        end
      end
      vars
    end
  end

  class << self
    def all
      build_servers
    end

    def find(name)
      all.find { |server| server.name == name }
    end

    def find!(name)
      find(name) || raise(ServerNotFoundError, "Server '#{name}' not found in catalog")
    end

    def names
      all.map(&:name)
    end

    def titles
      all.map(&:title)
    end

    def exists?(name)
      find(name).present?
    end

    # Canonical MCP server config hash used for OAuth credential-key computation.
    # Mirrors the shape Claude Code uses when deriving the credential key
    # (type, url, headers), so every caller hashes the same structure.
    #
    # @param name [String] the MCP server name
    # @return [Hash, nil] { type:, url?, headers? } or nil when the server is unknown
    def credential_config(name)
      server = find(name)
      return nil unless server

      config = { type: server.type }
      config[:url] = server.url if server.url
      config[:headers] = server.headers if server.headers&.any?
      config
    end

    def reload!
      AirCatalogService.reload!
      all
    end

    def config
      AirCatalogService.entries_for(:mcp)
    end

    private

    def build_servers
      AirCatalogService.entries_for(:mcp).map { |name, entry| Server.new(name, entry) }
    rescue AirCatalogService::CatalogError => e
      Rails.logger.warn "[ServersConfig] #{e.message}"
      []
    end
  end
end
