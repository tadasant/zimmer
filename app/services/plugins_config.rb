# frozen_string_literal: true

# Service class for managing plugin configurations from the centralized plugins catalog.
# Reads plugin entries from AirCatalogService, which discovers them via air.json.
class PluginsConfig
  class PluginNotFoundError < StandardError; end
  class ConfigurationError < StandardError; end

  # Plugin configuration object
  class Plugin
    attr_reader :id, :title, :description, :version, :skills, :mcp_servers, :hooks, :keywords

    def initialize(id, config)
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

    def find(id)
      plugins_by_id[id]
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

    def plugins_by_id
      all.index_by(&:id)
    end

    def build_plugins
      AirCatalogService.entries_for(:plugins).map { |id, entry| Plugin.new(id, entry) }
    rescue AirCatalogService::CatalogError => e
      Rails.logger.warn "[PluginsConfig] #{e.message}"
      []
    end
  end
end
