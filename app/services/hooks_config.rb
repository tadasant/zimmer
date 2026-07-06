# frozen_string_literal: true

# Service class for managing hook configurations from the centralized hooks catalog.
# Reads hook entries from AirCatalogService, which shells out to `air resolve --json`.
class HooksConfig
  class HookNotFoundError < StandardError; end
  class ConfigurationError < StandardError; end

  # Hook configuration object
  class Hook
    attr_reader :id, :name, :title, :description, :path

    def initialize(name, config)
      @id = name
      @name = name
      @title = config["title"] || name
      @description = config["description"]
      @path = config["path"]
    end

    # Absolute path to the hook's directory on disk.
    # `air resolve --json` absolutizes hook paths, so this is the resolved path as-is.
    def absolute_path
      @path
    end

    def to_h
      {
        id: id,
        name: name,
        title: title,
        description: description
      }
    end

    def to_json(*args)
      to_h.to_json(*args)
    end
  end

  class << self
    def all
      build_hooks
    end

    def find(name)
      hooks_by_name[name]
    end

    def find!(name)
      find(name) || raise(HookNotFoundError, "Hook '#{name}' not found in catalog")
    end

    def names
      all.map(&:name)
    end

    def exists?(name)
      find(name).present?
    end

    def reload!
      AirCatalogService.reload!
      all
    end

    def config
      AirCatalogService.entries_for(:hooks)
    end

    private

    def hooks_by_name
      all.index_by(&:name)
    end

    def build_hooks
      AirCatalogService.entries_for(:hooks).map { |name, entry| Hook.new(name, entry) }
    rescue AirCatalogService::CatalogError => e
      Rails.logger.warn "[HooksConfig] #{e.message}"
      []
    end
  end
end
