# frozen_string_literal: true

require "test_helper"

class SkillsConfigTest < ActiveSupport::TestCase
  # Test loading skills
  test "should load all skills from config" do
    skills = SkillsConfig.all
    assert skills.is_a?(Array)
    assert skills.all? { |s| s.is_a?(SkillsConfig::Skill) }
  end

  test "should have expected skills from config" do
    skill_names = SkillsConfig.names

    # Spot-check the Zimmer-specific skills from skills/skills.json in the catalog
    assert_includes skill_names, "zimmer-start-dev-server"
    assert_includes skill_names, "zimmer-run-tests"
    assert_includes skill_names, "zimmer-deploy-staging"
    assert_includes skill_names, "zimmer-change-ai-artifact"
    assert_includes skill_names, "sync-docs"
  end

  test "catalog holds only Zimmer-specific skills" do
    # Generic workflow skills (pr, wait-for-ci, analyze-agent-transcript) come from
    # the orchestrator's own default skill set. Registering them here too would
    # collide on shortname, and AIR hard-fails the whole resolve on a collision.
    skill_names = SkillsConfig.names

    assert_not_includes skill_names, "pr"
    assert_not_includes skill_names, "wait-for-ci"
    assert_not_includes skill_names, "analyze-agent-transcript"
  end

  # Test finding skills
  test "should find skill by name" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    assert_not_nil skill
    assert_equal "zimmer-start-dev-server", skill.name
  end

  test "should return nil for non-existent skill" do
    skill = SkillsConfig.find("nonexistent")
    assert_nil skill
  end

  test "should raise error with find! for non-existent skill" do
    assert_raises(SkillsConfig::SkillNotFoundError) do
      SkillsConfig.find!("nonexistent")
    end
  end

  test "should include skill name in error message" do
    error = assert_raises(SkillsConfig::SkillNotFoundError) do
      SkillsConfig.find!("missing_skill")
    end
    assert_includes error.message, "missing_skill"
  end

  # Test skill existence
  test "should return true for existing skill" do
    assert SkillsConfig.exists?("zimmer-start-dev-server")
    assert SkillsConfig.exists?("zimmer-deploy-staging")
  end

  test "should return false for non-existent skill" do
    assert_not SkillsConfig.exists?("nonexistent")
  end

  # Test skill names
  test "should return array of skill names" do
    names = SkillsConfig.names
    assert names.is_a?(Array)
    assert names.all? { |n| n.is_a?(String) }
  end

  # Test reload functionality
  test "should reload configuration" do
    initial_skills = SkillsConfig.all
    reloaded_skills = SkillsConfig.reload!
    assert_equal initial_skills.map(&:name), reloaded_skills.map(&:name)
  end

  # TTL/cache invalidation lives in AirCatalogService and is exercised in
  # AirCatalogServiceTest. SkillsConfig only delegates.

  # Test Skill object attributes
  test "skill should have name attribute" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    assert_not_nil skill.name
    assert_equal "zimmer-start-dev-server", skill.name
  end

  test "skill should have id attribute" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    assert_not_nil skill.id
    assert_equal "zimmer-start-dev-server", skill.id
  end

  test "skill should have title attribute" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    assert_not_nil skill.title
    assert skill.title.is_a?(String)
  end

  test "skill should have description attribute" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    assert skill.description.is_a?(String)
  end

  test "skill should have path attribute absolutized by air resolve" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    assert_not_nil skill.path
    assert_equal skill.path, skill.absolute_path
    assert skill.path.end_with?("skills/zimmer-start-dev-server"),
      "expected skill.path to end with 'skills/zimmer-start-dev-server', got #{skill.path.inspect}"
  end

  test "every registered skill has a SKILL.md body on disk" do
    # AIR validates references *between* entries but does not check that a skill's
    # path exists. A registered skill with no body resolves clean and then fails
    # silently at injection time, so assert the bodies are really there.
    SkillsConfig.all.each do |skill|
      body = File.join(skill.absolute_path, "SKILL.md")
      assert File.exist?(body), "skill #{skill.id.inspect} has no body at #{body}"
    end
  end

  test "skill should have references attribute" do
    skill = SkillsConfig.find("zimmer-change-ai-artifact")
    assert skill.references.is_a?(Array)
    assert_includes skill.references, "engineering-practices"
  end

  test "skill without references should have empty array" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    assert_equal [], skill.references
  end

  test "skill category comes from the explicit category field" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    assert_equal "zimmer", skill.category
  end

  test "skill category falls back to the parent directory when not declared" do
    skill = SkillsConfig::Skill.new("test", {
      "title" => "Test",
      "path" => "/catalog/skills/agent-orchestrator/some-skill"
    })
    assert_equal "agent-orchestrator", skill.category
  end

  # Test user_invocable
  test "skill should have user_invocable attribute" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    assert_includes [ true, false ], skill.user_invocable
  end

  test "skill user_invocable defaults to false when not specified" do
    skill = SkillsConfig::Skill.new("test", { "title" => "Test" })
    assert_equal false, skill.user_invocable
  end

  test "skill user_invocable respects explicit value" do
    skill_true = SkillsConfig::Skill.new("test", { "user_invocable" => true })
    assert_equal true, skill_true.user_invocable

    skill_false = SkillsConfig::Skill.new("test", { "user_invocable" => false })
    assert_equal false, skill_false.user_invocable
  end

  # Test to_h
  test "skill to_h should include id name title description category user_invocable" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    hash = skill.to_h

    assert_equal skill.id, hash[:id]
    assert_equal skill.name, hash[:name]
    assert_equal skill.title, hash[:title]
    assert_equal skill.description, hash[:description]
    assert_equal "zimmer", hash[:category]
    assert_includes [ true, false ], hash[:user_invocable]
  end

  test "skill to_h should not include files content or path" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    hash = skill.to_h

    assert_not hash.key?(:files)
    assert_not hash.key?(:content)
    assert_not hash.key?(:path)
  end

  # Test to_json
  test "skill to_json should be valid JSON" do
    skill = SkillsConfig.find("zimmer-start-dev-server")
    json = JSON.parse(skill.to_json)

    assert_equal skill.name, json["name"]
    assert_equal skill.title, json["title"]
  end

  # Test titles
  test "should return array of skill titles" do
    titles = SkillsConfig.titles
    assert titles.is_a?(Array)
    assert titles.all? { |t| t.is_a?(String) }
  end

  # Test categories
  test "should return unique sorted categories" do
    categories = SkillsConfig.categories
    assert categories.is_a?(Array)
    assert_includes categories, "zimmer"
    assert_equal categories, categories.sort
    assert_equal categories, categories.uniq
  end

  test "should group skills by category" do
    grouped = SkillsConfig.grouped_by_category
    assert grouped.is_a?(Hash)
    assert grouped.key?("zimmer")
    assert grouped["zimmer"].all? { |s| s.category == "zimmer" }
  end
end
