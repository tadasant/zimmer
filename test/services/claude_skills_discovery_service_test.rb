# frozen_string_literal: true

require "test_helper"

class ClaudeSkillsDiscoveryServiceTest < ActiveSupport::TestCase
  setup do
    @test_dir = Rails.root.join("tmp", "test_skills_#{SecureRandom.hex(8)}")
    FileUtils.mkdir_p(@test_dir)
  end

  teardown do
    FileUtils.rm_rf(@test_dir) if @test_dir && Dir.exist?(@test_dir)
  end

  # ============================================================================
  # Basic Discovery Tests
  # ============================================================================

  test "returns empty array when directory does not exist" do
    result = ClaudeSkillsDiscoveryService.discover("/nonexistent/path")
    assert_equal [], result
  end

  test "returns empty array when .claude directory does not exist" do
    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)
    assert_equal [], result
  end

  test "returns empty array when .claude directory is empty" do
    claude_dir = @test_dir.join(".claude")
    FileUtils.mkdir_p(claude_dir)

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)
    assert_equal [], result
  end

  # ============================================================================
  # Skill Discovery Tests
  # ============================================================================

  test "discovers skills from .claude/skills directory" do
    create_skill(@test_dir, "my-skill", "Does something useful")

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal "my-skill", result[0][:name]
    assert_equal "Does something useful", result[0][:description]
    assert_equal "skill", result[0][:type]
  end

  test "discovers multiple skills" do
    create_skill(@test_dir, "skill-a", "Description A")
    create_skill(@test_dir, "skill-b", "Description B")
    create_skill(@test_dir, "skill-c", "Description C")

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 3, result.length
    names = result.map { |s| s[:name] }
    assert_includes names, "skill-a"
    assert_includes names, "skill-b"
    assert_includes names, "skill-c"
  end

  test "extracts skill name from frontmatter" do
    create_skill_with_content(@test_dir, "skill-folder", <<~MARKDOWN)
      ---
      name: custom-name
      description: Custom description
      ---

      # Custom Name

      This skill does something.
    MARKDOWN

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal "custom-name", result[0][:name]
    assert_equal "Custom description", result[0][:description]
  end

  test "falls back to folder name when no frontmatter name" do
    create_skill_with_content(@test_dir, "my-folder-name", <<~MARKDOWN)
      # Skill Title

      This skill does something.
    MARKDOWN

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal "my-folder-name", result[0][:name]
  end

  # ============================================================================
  # Command Discovery Tests
  # ============================================================================

  test "discovers commands from .claude/commands directory" do
    create_command(@test_dir, "start", "Starts the workflow")

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal "start", result[0][:name]
    assert_equal "Starts the workflow", result[0][:description]
    assert_equal "command", result[0][:type]
  end

  test "extracts command name from frontmatter" do
    create_command_with_content(@test_dir, "run.md", <<~MARKDOWN)
      ---
      name: custom-command
      description: Custom command description
      ---

      # Run Command

      Instructions here.
    MARKDOWN

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal "custom-command", result[0][:name]
    assert_equal "Custom command description", result[0][:description]
  end

  test "falls back to filename without extension for command name" do
    create_command_with_content(@test_dir, "my-command.md", <<~MARKDOWN)
      # My Command

      Instructions here.
    MARKDOWN

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal "my-command", result[0][:name]
  end

  # ============================================================================
  # Combined Discovery Tests
  # ============================================================================

  test "discovers both skills and commands" do
    create_skill(@test_dir, "my-skill", "Skill description")
    create_command(@test_dir, "my-command", "Command description")

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 2, result.length
    types = result.map { |s| s[:type] }
    assert_includes types, "skill"
    assert_includes types, "command"
  end

  # ============================================================================
  # Monorepo Discovery Tests (working directory + clone root)
  # ============================================================================

  test "discovers skills from both working directory and clone root" do
    # Create root .claude directory
    create_skill(@test_dir, "root-skill", "Root skill")

    # Create subdirectory with its own .claude
    subdir = @test_dir.join("subproject")
    FileUtils.mkdir_p(subdir)
    create_skill(subdir, "subdir-skill", "Subdir skill")

    result = ClaudeSkillsDiscoveryService.discover(subdir.to_s, clone_path: @test_dir.to_s)

    assert_equal 2, result.length
    names = result.map { |s| s[:name] }
    assert_includes names, "root-skill"
    assert_includes names, "subdir-skill"
  end

  test "prefers working directory skill over root skill with same name" do
    # Create skill in root
    create_skill(@test_dir, "shared-skill", "Root version")

    # Create skill with same name in subdirectory
    subdir = @test_dir.join("subproject")
    FileUtils.mkdir_p(subdir)
    create_skill(subdir, "shared-skill", "Subdir version")

    result = ClaudeSkillsDiscoveryService.discover(subdir.to_s, clone_path: @test_dir.to_s)

    # Should only have one, from the working directory
    skill = result.find { |s| s[:name] == "shared-skill" }
    assert_equal "Subdir version", skill[:description]
    assert_equal 1, result.count { |s| s[:name] == "shared-skill" }
  end

  # ============================================================================
  # Sorting Tests
  # ============================================================================

  test "sorts results by name length then alphabetically" do
    create_skill(@test_dir, "zzz", "Short name")
    create_skill(@test_dir, "aaa", "Short name")
    create_skill(@test_dir, "medium-name", "Medium name")
    create_skill(@test_dir, "very-long-skill-name", "Long name")

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    names = result.map { |s| s[:name] }
    # Sorted by length first, then alphabetically
    assert_equal %w[aaa zzz medium-name very-long-skill-name], names
  end

  # ============================================================================
  # User-Invocable Field Tests
  # ============================================================================

  test "includes user_invocable field defaulting to false when not specified" do
    create_skill(@test_dir, "my-skill", "Does something useful")

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal false, result[0][:user_invocable]
  end

  test "parses user-invocable: true from frontmatter" do
    create_skill_with_content(@test_dir, "invocable-skill", <<~MARKDOWN)
      ---
      name: invocable-skill
      description: A user-invocable skill
      user-invocable: true
      ---

      # Invocable Skill

      This skill can be invoked by users.
    MARKDOWN

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal true, result[0][:user_invocable]
  end

  test "parses user-invocable: false from frontmatter" do
    create_skill_with_content(@test_dir, "internal-skill", <<~MARKDOWN)
      ---
      name: internal-skill
      description: An internal skill not for user invocation
      user-invocable: false
      ---

      # Internal Skill

      This skill is used internally by other skills.
    MARKDOWN

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal false, result[0][:user_invocable]
  end

  test "includes user_invocable field for commands defaulting to false" do
    create_command(@test_dir, "my-command", "A user command")

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal false, result[0][:user_invocable]
  end

  test "parses user-invocable: false from command frontmatter" do
    create_command_with_content(@test_dir, "internal-command.md", <<~MARKDOWN)
      ---
      name: internal-command
      description: An internal command
      user-invocable: false
      ---

      # Internal Command

      This command is internal.
    MARKDOWN

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)

    assert_equal 1, result.length
    assert_equal false, result[0][:user_invocable]
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  test "handles malformed frontmatter gracefully" do
    create_skill_with_content(@test_dir, "bad-skill", <<~MARKDOWN)
      ---
      name: [invalid yaml
      ---

      # Content
    MARKDOWN

    # Should not raise, should return something
    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)
    assert_equal 1, result.length
    # Falls back to folder name when frontmatter is invalid
    assert_equal "bad-skill", result[0][:name]
  end

  test "handles empty skill file" do
    skill_dir = @test_dir.join(".claude", "skills", "empty-skill")
    FileUtils.mkdir_p(skill_dir)
    File.write(skill_dir.join("SKILL.md"), "")

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)
    assert_equal [], result
  end

  test "handles skill directory without SKILL.md file" do
    skill_dir = @test_dir.join(".claude", "skills", "no-file")
    FileUtils.mkdir_p(skill_dir)

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)
    assert_equal [], result
  end

  test "extracts description from content when not in frontmatter" do
    create_skill_with_content(@test_dir, "no-desc", <<~MARKDOWN)
      ---
      name: no-desc
      ---

      # Skill Title

      This is the first paragraph that should become the description.

      More content here.
    MARKDOWN

    result = ClaudeSkillsDiscoveryService.discover(@test_dir.to_s)
    assert_equal 1, result.length
    assert_includes result[0][:description], "first paragraph"
  end

  private

  def create_skill(base_dir, name, description)
    skill_dir = base_dir.join(".claude", "skills", name)
    FileUtils.mkdir_p(skill_dir)
    content = <<~MARKDOWN
      ---
      name: #{name}
      description: #{description}
      ---

      # #{name.titleize}

      Instructions for this skill.
    MARKDOWN
    File.write(skill_dir.join("SKILL.md"), content)
  end

  def create_skill_with_content(base_dir, folder_name, content)
    skill_dir = base_dir.join(".claude", "skills", folder_name)
    FileUtils.mkdir_p(skill_dir)
    File.write(skill_dir.join("SKILL.md"), content)
  end

  def create_command(base_dir, name, description)
    commands_dir = base_dir.join(".claude", "commands")
    FileUtils.mkdir_p(commands_dir)
    content = <<~MARKDOWN
      ---
      name: #{name}
      description: #{description}
      ---

      # #{name.titleize}

      Instructions for this command.
    MARKDOWN
    File.write(commands_dir.join("#{name}.md"), content)
  end

  def create_command_with_content(base_dir, filename, content)
    commands_dir = base_dir.join(".claude", "commands")
    FileUtils.mkdir_p(commands_dir)
    File.write(commands_dir.join(filename), content)
  end
end
