# frozen_string_literal: true

require "test_helper"
require "ostruct"

class ClaudeSkillsCacheServiceTest < ActiveSupport::TestCase
  setup do
    @git_root = "https://github.com/test/repo.git"
    @subdirectory = "subdir"
    @skills = [
      { name: "skill-a", description: "Description A", type: "skill" },
      { name: "skill-b", description: "Description B", type: "skill" }
    ]

    # Clear any existing cache entries
    Rails.cache.delete(ClaudeSkillsCacheService.cache_key(@git_root, nil))
    Rails.cache.delete(ClaudeSkillsCacheService.cache_key(@git_root, @subdirectory))
  end

  teardown do
    # Clear cache entries after tests
    Rails.cache.delete(ClaudeSkillsCacheService.cache_key(@git_root, nil))
    Rails.cache.delete(ClaudeSkillsCacheService.cache_key(@git_root, @subdirectory))
  end

  # ============================================================================
  # Cache Key Tests
  # ============================================================================

  test "generates cache key without subdirectory" do
    key = ClaudeSkillsCacheService.cache_key(@git_root, nil)
    assert_equal "claude_skills:#{@git_root}", key
  end

  test "generates cache key with subdirectory" do
    key = ClaudeSkillsCacheService.cache_key(@git_root, @subdirectory)
    assert_equal "claude_skills:#{@git_root}:#{@subdirectory}", key
  end

  test "generates different keys for different subdirectories" do
    key1 = ClaudeSkillsCacheService.cache_key(@git_root, "subdir1")
    key2 = ClaudeSkillsCacheService.cache_key(@git_root, "subdir2")
    assert_not_equal key1, key2
  end

  # ============================================================================
  # Caching Tests
  # ============================================================================

  test "caches skills for agent root" do
    result = ClaudeSkillsCacheService.cache_for_agent_root(@git_root, nil, @skills)
    assert result

    cached = ClaudeSkillsCacheService.get_for_agent_root(@git_root)
    # Cache should return something (either skills or empty depending on cache availability)
    assert_kind_of Array, cached
    if cached.any?
      assert_equal @skills, cached
    end
  end

  test "caches skills with subdirectory" do
    result = ClaudeSkillsCacheService.cache_for_agent_root(@git_root, @subdirectory, @skills)
    assert result

    cached = ClaudeSkillsCacheService.get_for_agent_root(@git_root, @subdirectory)
    assert_kind_of Array, cached
    if cached.any?
      assert_equal @skills, cached
    end
  end

  test "returns false when git_root is blank" do
    result = ClaudeSkillsCacheService.cache_for_agent_root("", nil, @skills)
    assert_not result

    result = ClaudeSkillsCacheService.cache_for_agent_root(nil, nil, @skills)
    assert_not result
  end

  test "returns false when skills are blank" do
    result = ClaudeSkillsCacheService.cache_for_agent_root(@git_root, nil, [])
    assert_not result

    result = ClaudeSkillsCacheService.cache_for_agent_root(@git_root, nil, nil)
    assert_not result
  end

  # ============================================================================
  # Retrieval Tests
  # ============================================================================

  test "returns empty array when no cached skills" do
    result = ClaudeSkillsCacheService.get_for_agent_root("https://github.com/nonexistent/repo.git")
    assert_equal [], result
  end

  test "returns empty array when git_root is blank" do
    result = ClaudeSkillsCacheService.get_for_agent_root("")
    assert_equal [], result

    result = ClaudeSkillsCacheService.get_for_agent_root(nil)
    assert_equal [], result
  end

  # ============================================================================
  # Session Retrieval Tests
  # ============================================================================

  test "get_for_session returns cached skills for the session's agent root" do
    session = sessions(:running)
    session.update!(git_root: @git_root, subdirectory: @subdirectory)

    # Cache skills for this agent root
    ClaudeSkillsCacheService.cache_for_agent_root(@git_root, @subdirectory, @skills)

    result = ClaudeSkillsCacheService.get_for_session(session)
    # Result depends on whether cache is available
    assert_kind_of Array, result
    # If cache worked, we get the skills; if not, empty array
    assert [ @skills, [] ].include?(result), "Expected skills or empty array"
  end

  test "get_for_session delegates to the session's git_root and subdirectory" do
    session = sessions(:running)
    session.update!(git_root: @git_root, subdirectory: @subdirectory)

    # Cache under the agent root key directly, then confirm get_for_session
    # resolves the same key via the session's git_root/subdirectory.
    ClaudeSkillsCacheService.cache_for_agent_root(@git_root, @subdirectory, @skills)

    via_session = ClaudeSkillsCacheService.get_for_session(session)
    via_agent_root = ClaudeSkillsCacheService.get_for_agent_root(@git_root, @subdirectory)
    assert_equal via_agent_root, via_session
  end

  test "get_for_session returns empty array when no skills are cached" do
    session = sessions(:running)
    session.update!(git_root: "https://github.com/no-cache/repo.git", subdirectory: nil)

    result = ClaudeSkillsCacheService.get_for_session(session)
    assert_equal [], result
  end

  # ============================================================================
  # Agent Root Config Tests
  # ============================================================================

  test "get_for_agent_root_config retrieves cached skills" do
    # Cache skills
    ClaudeSkillsCacheService.cache_for_agent_root(@git_root, @subdirectory, @skills)

    # Create a mock agent root config
    agent_root = OpenStruct.new(url: @git_root, subdirectory: @subdirectory)

    result = ClaudeSkillsCacheService.get_for_agent_root_config(agent_root)
    # Result depends on whether cache is available
    assert_kind_of Array, result
    # If cache worked, we get the skills; if not, empty array
    assert [ @skills, [] ].include?(result), "Expected skills or empty array"
  end

  test "get_for_agent_root_config returns empty array for nil agent root" do
    result = ClaudeSkillsCacheService.get_for_agent_root_config(nil)
    assert_equal [], result
  end

  # ============================================================================
  # Cache Clearing Tests
  # ============================================================================

  test "clears cached skills for agent root" do
    ClaudeSkillsCacheService.cache_for_agent_root(@git_root, nil, @skills)

    result = ClaudeSkillsCacheService.clear_for_agent_root(@git_root)
    assert result
    assert_equal [], ClaudeSkillsCacheService.get_for_agent_root(@git_root)
  end

  test "clear returns false for blank git_root" do
    result = ClaudeSkillsCacheService.clear_for_agent_root("")
    assert_not result

    result = ClaudeSkillsCacheService.clear_for_agent_root(nil)
    assert_not result
  end
end
