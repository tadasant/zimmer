# frozen_string_literal: true

# Service class for managing reference configurations.
# Reads reference entries from AirCatalogService, which shells out to `air resolve --json`.
class ReferencesConfig
  class ReferenceNotFoundError < StandardError; end
  class ConfigurationError < StandardError; end

  # Reference configuration object
  class Reference
    attr_reader :id, :title, :description, :file, :path

    def initialize(id, config)
      @id = id
      @title = config["title"] || id
      @description = config["description"]
      # Local catalog entries carry `file` (a path relative to references.json).
      # GitHub-catalog entries carry `path` (an absolute path on disk resolved
      # by AIR into the provider cache). Both are valid; callers that need a
      # resolvable path should prefer `path` and fall back to `file`.
      @file = config["file"]
      @path = config["path"]
    end

    def to_h
      {
        id: id,
        title: title,
        description: description,
        file: file,
        path: path
      }
    end

    def to_json(*args)
      to_h.to_json(*args)
    end
  end

  class << self
    def all
      build_references
    end

    def find(id)
      refs_by_id[id]
    end

    def find!(id)
      find(id) || raise(ReferenceNotFoundError, "Reference '#{id}' not found in catalog")
    end

    def exists?(id)
      find(id).present?
    end

    def ids
      all.map(&:id)
    end

    def reload!
      AirCatalogService.reload!
      all
    end

    def config
      AirCatalogService.entries_for(:references)
    end

    private

    def refs_by_id
      all.index_by(&:id)
    end

    def build_references
      AirCatalogService.entries_for(:references).map { |id, entry| Reference.new(id, entry) }
    rescue AirCatalogService::CatalogError => e
      Rails.logger.warn "[ReferencesConfig] #{e.message}"
      []
    end
  end
end
