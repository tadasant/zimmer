# frozen_string_literal: true

# Service for caching and retrieving Claude skills by agent root
#
# Skills are cached in Rails.cache using the agent root (git_root + subdirectory)
# as the key. This allows the typeahead to work in the Initial Prompt form
# before a clone exists.
class ClaudeSkillsCacheService
  CACHE_PREFIX = "claude_skills"
  CACHE_EXPIRY = 24.hours

  class << self
    # Generate cache key for an agent root
    #
    # @param git_root [String] The git repository URL
    # @param subdirectory [String, nil] Optional subdirectory within the repo
    # @return [String] The cache key
    def cache_key(git_root, subdirectory = nil)
      key_parts = [ CACHE_PREFIX, git_root ]
      key_parts << subdirectory if subdirectory.present?
      key_parts.join(":")
    end

    # Cache skills for an agent root
    #
    # @param git_root [String] The git repository URL
    # @param subdirectory [String, nil] Optional subdirectory within the repo
    # @param skills [Array<Hash>] Array of skill hashes to cache
    # @return [Boolean] Whether the cache write succeeded
    def cache_for_agent_root(git_root, subdirectory, skills)
      return false if git_root.blank? || skills.blank?

      key = cache_key(git_root, subdirectory)
      Rails.cache.write(key, skills, expires_in: CACHE_EXPIRY)
      true
    rescue => e
      Rails.logger.error "Failed to cache Claude skills: #{e.message}"
      false
    end

    # Retrieve cached skills for an agent root
    #
    # @param git_root [String] The git repository URL
    # @param subdirectory [String, nil] Optional subdirectory within the repo
    # @return [Array<Hash>] Array of skill hashes (empty if not cached)
    def get_for_agent_root(git_root, subdirectory = nil)
      return [] if git_root.blank?

      key = cache_key(git_root, subdirectory)
      Rails.cache.read(key) || []
    rescue => e
      Rails.logger.error "Failed to read cached Claude skills: #{e.message}"
      []
    end

    # Get skills for a session via the agent-root-scoped cache.
    #
    # Skills discovered during session setup are cached by agent root (see
    # AgentSessionJob), so the lookup is keyed on the session's git_root +
    # subdirectory rather than persisted per-session.
    #
    # @param session [Session] The session to get skills for
    # @return [Array<Hash>] Array of skill hashes
    def get_for_session(session)
      get_for_agent_root(session.git_root, session.subdirectory)
    end

    # Get skills for an agent root configuration (for Initial Prompt form)
    #
    # @param agent_root [AgentRootsConfig::AgentRoot] The agent root configuration
    # @return [Array<Hash>] Array of skill hashes
    def get_for_agent_root_config(agent_root)
      return [] unless agent_root

      get_for_agent_root(agent_root.url, agent_root.subdirectory)
    end

    # Clear cached skills for an agent root
    #
    # @param git_root [String] The git repository URL
    # @param subdirectory [String, nil] Optional subdirectory within the repo
    # @return [Boolean] Whether the cache delete succeeded
    def clear_for_agent_root(git_root, subdirectory = nil)
      return false if git_root.blank?

      key = cache_key(git_root, subdirectory)
      Rails.cache.delete(key)
      true
    rescue => e
      Rails.logger.error "Failed to clear cached Claude skills: #{e.message}"
      false
    end
  end
end
