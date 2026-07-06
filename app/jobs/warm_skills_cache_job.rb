# frozen_string_literal: true

# Background job to proactively warm the Claude skills cache for all configured agent roots.
#
# The follow-up prompt form's slash command typeahead relies on cached skills
# (via ClaudeSkillsCacheService), but the cache was previously only populated as
# a side effect of creating a session. This job ensures the cache stays warm by
# periodically discovering skills from:
#   1. Repo-native .claude/skills/ and .claude/commands/ directories — when the agent
#      root's URL matches a github source declared in air.json, we use that source's
#      cached clone.
#   2. Default catalog skills configured for each agent root (read directly from the
#      AirCatalogService entries).
#
# Note: The session creation page derives its typeahead from selected catalog skills
# directly (not from this cache). This job serves the follow-up prompt flow.
#
# Runs every 4 hours via cron. The 24-hour cache TTL means the cache stays warm
# between job runs even if one run is missed.
class WarmSkillsCacheJob < ApplicationJob
  queue_as :pollers

  good_job_control_concurrency_with(
    key: -> { "warm_skills_cache" },
    total_limit: 1
  )

  def perform
    warmed = 0
    skipped = 0

    AgentRootsConfig.all.each do |agent_root|
      next if agent_root.custom?
      next if agent_root.url.blank?

      skills = discover_skills_for(agent_root)
      if skills.any?
        ClaudeSkillsCacheService.cache_for_agent_root(agent_root.url, agent_root.subdirectory, skills)
        warmed += 1
      else
        skipped += 1
      end
    rescue => e
      Rails.logger.warn "[WarmSkillsCacheJob] Failed to warm cache for #{agent_root.name}: #{e.message}"
      skipped += 1
    end

    Rails.logger.info "[WarmSkillsCacheJob] Warmed skills cache for #{warmed} agent root(s), skipped #{skipped}"
  end

  private

  # Discover all skills (repo-native + catalog defaults) for an agent root.
  def discover_skills_for(agent_root)
    repo_skills = discover_repo_native_skills(agent_root)
    catalog_skills = resolve_default_catalog_skills(agent_root)

    combine_skills(repo_skills, catalog_skills)
  end

  # Discover repo-native skills from a github source clone, when the agent root's URL
  # matches a github source declared in air.json. Other URLs are skipped since we don't
  # have their clones available locally.
  def discover_repo_native_skills(agent_root)
    clone_path = AirCatalogService.repo_root_for(url: agent_root.url)
    return [] unless clone_path

    working_directory = if agent_root.subdirectory.present?
      File.join(clone_path, agent_root.subdirectory)
    else
      clone_path
    end

    return [] unless File.directory?(working_directory)

    ClaudeSkillsDiscoveryService.discover(working_directory, clone_path: clone_path)
  end

  # Resolve default catalog skills for an agent root by reading SKILL.md files from
  # each skill's resolved directory (absolutized by `air resolve --json`).
  def resolve_default_catalog_skills(agent_root)
    return [] if agent_root.default_skills.blank?

    agent_root.default_skills.filter_map do |skill_name|
      next if skill_name.include?("..") || skill_name.include?("/")

      skill_config = SkillsConfig.find(skill_name)
      next unless skill_config&.absolute_path.present?

      skill_dir = skill_config.absolute_path
      skill_file = File.join(skill_dir, "SKILL.md")
      next unless File.exist?(skill_file)

      parse_catalog_skill(skill_file, skill_name)
    end
  end

  # Parse a catalog SKILL.md file into the same hash format that
  # ClaudeSkillsDiscoveryService produces.
  def parse_catalog_skill(file_path, fallback_name)
    content = File.read(file_path)
    return nil if content.blank?

    frontmatter = ClaudeSkillsDiscoveryService.extract_frontmatter(content)
    name = frontmatter["name"].presence || fallback_name
    description = frontmatter["description"] || ""
    user_invocable = frontmatter.fetch("user-invocable", false)

    {
      name: name,
      description: description,
      type: "skill",
      user_invocable: user_invocable
    }
  rescue => e
    Rails.logger.warn "[WarmSkillsCacheJob] Failed to parse catalog skill #{file_path}: #{e.message}"
    nil
  end

  # Combine repo-native and catalog skills, deduplicating by name.
  # Repo-native skills take priority over catalog skills.
  def combine_skills(repo_skills, catalog_skills)
    seen_names = Set.new
    combined = []

    repo_skills.each do |skill|
      key = "#{skill[:type]}:#{skill[:name]}"
      unless seen_names.include?(key)
        seen_names.add(key)
        combined << skill
      end
    end

    catalog_skills.each do |skill|
      key = "#{skill[:type]}:#{skill[:name]}"
      unless seen_names.include?(key)
        seen_names.add(key)
        combined << skill
      end
    end

    combined.sort_by { |s| [ s[:name].length, s[:name].downcase ] }
  end
end
