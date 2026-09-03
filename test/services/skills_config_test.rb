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

  test "catalog vendors the generic workflow skills alongside the Zimmer-specific ones" do
    # The catalog is the only source of skills: it is self-contained and single-scope
    # (everything resolves under @local/), so a standalone install inherits nothing
    # from an outside orchestrator. Generic workflow skills are vendored here under
    # category "workflow", distinct from the Zimmer-specific ones under "zimmer".
    skill_names = SkillsConfig.names

    assert_includes skill_names, "open-pr"
    assert_includes skill_names, "wait-for-ci"
    assert_includes skill_names, "recover-from-compaction-thrashing"

    %w[open-pr wait-for-ci recover-from-compaction-thrashing].each do |name|
      assert_equal "workflow", SkillsConfig.find(name).category,
        "#{name} should be grouped under the workflow category"
    end

    # Not every generic skill is vendored — only the ones Zimmer actually ships.
    assert_not_includes skill_names, "analyze-agent-transcript"
  end

  test "the open-pr skill bundles the git-workflow reference its links resolve against" do
    # skills/open-pr/SKILL.md deep-links references/GIT_WORKFLOW.md; AIR bundles the
    # reference into .claude/skills/open-pr/references/ at prepare time. Without this
    # wiring those links are dead.
    assert_includes SkillsConfig.find("open-pr").references, "git-workflow"
  end

  test "the vendored open-pr skill carries both terminal steps" do
    # Three places tell a session to "follow the open-pr skill's terminal steps"
    # when coming to rest on an open PR: OrchestratorSystemPromptBuilder's
    # sanctioned needs_input reason 2, config/goals.json, and the action_session
    # MCP tool description. A session on a root that resolves this vendored copy
    # must actually find them there. The copy drifted behind once already (#682).
    body = File.read(File.join(SkillsConfig.find("open-pr").absolute_path, "SKILL.md"))

    assert_includes body, "## Terminal Step 1", "open-pr lost the ready-to-merge label step"
    assert_includes body, "## Terminal Step 2", "open-pr lost the bounded self-wake step"
    assert_includes body, "ready to merge"
    assert_includes body, "wake_me_up_later"
    assert_includes body, "needs_input"
  end

  test "no skill links a reference or a heading the catalog does not carry" do
    # A `references/FOO.md` link in a SKILL.md only resolves because AIR bundles
    # the reference at prepare time, which it only does for references the skill
    # declares. A link to a reference this catalog does not carry — or to a heading
    # that is not in it — is dead prose: nothing fails to resolve, so nothing
    # catches it but this test.
    references_by_file = ReferencesConfig.all.index_by(&:file).except(nil)

    SkillsConfig.all.each do |skill|
      body_path = File.join(skill.absolute_path, "SKILL.md")
      body = File.read(body_path)

      body.scan(%r{\]\((?:\./|\.\./)*(references/[^)\s#]+)(#[^)\s]+)?\)}).each do |link, anchor|
        file = File.basename(link)
        reference = references_by_file[file]

        assert_not_nil reference,
          "#{skill.id} links #{link} but no catalog reference has file #{file}"
        assert_includes skill.references, reference.id,
          "#{skill.id} links #{link} but does not declare reference #{reference.id.inspect}"

        reference_path = reference.path || Rails.root.join("references", reference.file).to_s
        assert File.exist?(reference_path), "reference #{reference.id} missing at #{reference_path}"

        next if anchor.blank?

        assert_includes markdown_heading_slugs(reference_path), anchor.delete_prefix("#"),
          "#{skill.id} links #{link}#{anchor} but #{file} has no such heading"
      end

      # Same hazard one level in: a re-vendored skill routinely renames or drops a
      # section, and its own in-page anchors go stale silently when it does.
      own_slugs = markdown_heading_slugs(body_path)
      body.scan(%r{\]\(#([^)\s]+)\)}).flatten.each do |anchor|
        assert_includes own_slugs, anchor,
          "#{skill.id} links ##{anchor} but its own body has no such heading"
      end
    end
  end

  test "every skill's frontmatter agrees with its catalog entry" do
    # The two are read by different surfaces: SkillsConfig (the index) feeds the
    # session-creation skill picker, while ClaudeSkillsDiscoveryService and
    # WarmSkillsCacheJob parse the frontmatter for the slash-command typeahead.
    # Drift between them is the same silent failure class as #682.
    SkillsConfig.all.each do |skill|
      frontmatter = YAML.safe_load(File.read(File.join(skill.absolute_path, "SKILL.md")).split(/^---$/)[1].to_s)

      assert_equal skill.id, frontmatter["name"],
        "#{skill.id}: SKILL.md frontmatter name is #{frontmatter["name"].inspect}"
      assert_equal skill.user_invocable, frontmatter.fetch("user-invocable", false),
        "#{skill.id}: skills.json user_invocable disagrees with the frontmatter"
    end
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

  private

  def markdown_heading_slugs(path)
    in_fence = false

    File.readlines(path).filter_map do |line|
      in_fence = !in_fence if line.start_with?("```")
      next if in_fence || !line.start_with?("#")

      line.sub(/\A#+/, "").strip.delete("`").downcase.gsub(/[^a-z0-9 \-_]/, "").tr(" ", "-")
    end
  end
end
