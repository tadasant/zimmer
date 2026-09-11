# frozen_string_literal: true

# Service class for managing skill configurations from the centralized skills catalog.
# Reads skill entries from AirCatalogService, which shells out to `air resolve --json`.
class SkillsConfig
  class SkillNotFoundError < StandardError; end
  class ConfigurationError < StandardError; end

  # Skill configuration object
  class Skill
    include ArtifactIdentity::Entry

    attr_reader :id, :name, :title, :description, :path, :category, :references, :user_invocable

    def initialize(name, config)
      identify!(name, config)
      @id = config["id"] || name
      @name = name
      @title = config["title"] || name
      @description = config["description"]
      @path = config["path"]
      @category = config["category"].presence || path_category(@path)
      @references = config["references"] || []
      @user_invocable = config.fetch("user_invocable", false)
    end

    # Absolute path to the skill's directory on disk (e.g. for SKILL.md lookups).
    # `air resolve --json` absolutizes skill paths, so this is the resolved path as-is.
    def absolute_path
      @path
    end

    # Convert to hash representation (excludes content for API responses)
    def to_h
      {
        id: id,
        name: name,
        qualified_name: qualified_name,
        title: title,
        description: description,
        category: category,
        user_invocable: user_invocable
      }
    end

    def to_json(*args)
      to_h.to_json(*args)
    end

    private

    # Fallback category for entries that don't declare one: the resolved
    # directory's parent (e.g. "agent-orchestrator" in
    # "/.../skills/agent-orchestrator/ao-bump-mcp-versions"). This only yields a
    # useful label when a catalog groups its skills into subdirectories by
    # category. Catalogs that lay skills out flat (one directory per skill, as
    # Zimmer's `skills/` does) should set `category` explicitly in skills.json —
    # otherwise every skill would land under a group named after the containing
    # directory. The UI groups the skill picker by this value.
    def path_category(path)
      return nil if path.blank?
      File.basename(File.dirname(path))
    end
  end

  class << self
    # Get all available skills (auto-reloads via AirCatalogService TTL).
    # @return [Array<Skill>] list of skill objects
    def all
      build_skills
    end

    # Find a skill by name — a canonical token, a fully-qualified `@scope/id`,
    # or a bare short id exactly one catalog contributes. See
    # ArtifactIdentity.find.
    def find(name)
      ArtifactIdentity.find(all, name)
    end

    # Find a skill by name, raise error if not found
    def find!(name)
      find(name) || raise(SkillNotFoundError, "Skill '#{name}' not found in catalog")
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

    def categories
      all.filter_map(&:category).uniq.sort
    end

    def grouped_by_category
      all.group_by { |s| s.category || "uncategorized" }
    end

    # Force AirCatalogService to reload from disk.
    def reload!
      AirCatalogService.reload!
      all
    end

    # Raw merged entry hash keyed by name. Used by DeploymentInfoService to
    # surface the catalog as JSON on the settings page.
    #
    # Degrades the same way `all` does. This is the settings page's read
    # (DeploymentInfoService), and /settings is where an operator goes to clear
    # a bad catalog pin — so a resolve failure with no last-known-good fallback
    # must render an empty catalog there, not a 500 on the page holding the fix.
    def config
      AirCatalogService.entries_for(:skills)
    rescue AirCatalogService::CatalogError => e
      Rails.logger.warn "[SkillsConfig] catalog unavailable: #{e.message}"
      {}
    end

    private

    def build_skills
      AirCatalogService.entries_for(:skills).map { |name, entry| Skill.new(name, entry) }
    rescue AirCatalogService::CatalogError => e
      Rails.logger.warn "[SkillsConfig] #{e.message}"
      []
    end
  end
end
