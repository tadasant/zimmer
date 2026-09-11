# frozen_string_literal: true

# Service class for managing plugin configurations from the centralized plugins catalog.
# Reads plugin entries from AirCatalogService, which discovers them via air.json.
class PluginsConfig
  class PluginNotFoundError < StandardError; end
  class ConfigurationError < StandardError; end

  # Plugin configuration object
  class Plugin
    include ArtifactIdentity::Entry

    attr_reader :id, :title, :description, :version, :skills, :mcp_servers, :hooks, :keywords

    def initialize(id, config)
      identify!(id, config)
      @id = id
      @title = config["title"] || id
      @description = config["description"]
      @version = config["version"]
      @skills = config["skills"] || []
      @mcp_servers = config["mcp_servers"] || []
      @hooks = config["hooks"] || []
      @keywords = config["keywords"] || []
    end

    def to_h
      {
        id: id,
        qualified_name: qualified_name,
        title: title,
        description: description,
        version: version,
        skills: skills,
        mcp_servers: mcp_servers,
        hooks: hooks,
        keywords: keywords
      }
    end

    def to_json(*args)
      to_h.to_json(*args)
    end
  end

  class << self
    def all
      build_plugins
    end

    # Accepts a canonical token, a fully-qualified `@scope/id`, or a bare short
    # id that exactly one catalog contributes. See ArtifactIdentity.find.
    def find(id)
      ArtifactIdentity.find(all, id)
    end

    def find!(id)
      find(id) || raise(PluginNotFoundError, "Plugin '#{id}' not found in catalog")
    end

    def ids
      all.map(&:id)
    end

    def exists?(id)
      find(id).present?
    end

    def reload!
      AirCatalogService.reload!
      all
    end

    def config
      AirCatalogService.entries_for(:plugins)
    end

    private

    def build_plugins
      AirCatalogService.entries_for(:plugins).map { |id, entry| Plugin.new(id, entry) }
    rescue AirCatalogService::CatalogError => e
      Rails.logger.warn "[PluginsConfig] #{e.message}"
      []
    end
  end
end
