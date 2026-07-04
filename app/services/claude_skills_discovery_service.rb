# frozen_string_literal: true

require "yaml"

# Service for discovering Claude skills and commands in .claude directories
#
# Skills and commands are defined in Markdown files with YAML frontmatter:
#   - Skills: .claude/skills/<name>/SKILL.md
#   - Commands: .claude/commands/<name>.md
#
# Returns arrays of hashes with :name, :description, :type (skill/command), and :user_invocable
class ClaudeSkillsDiscoveryService
  class << self
    # Allow injection of file system for testing
    attr_writer :file_system

    def file_system
      @file_system ||= RealFileSystemAdapter.new
    end

    # Discover all skills and commands in a working directory
    # Looks in .claude directories both at the working directory level
    # and at the root of the clone (if different)
    #
    # @param working_directory [String] The working directory path
    # @param clone_path [String, nil] Optional clone root path (for monorepo subdirectories)
    # @return [Array<Hash>] Array of skill/command hashes sorted by name length then alphabetically
    def discover(working_directory, clone_path: nil)
      skills = []

      # Discover from working directory
      skills.concat(discover_from_directory(working_directory))

      # If clone_path is different (monorepo with subdirectory), also check root .claude
      if clone_path.present? && clone_path != working_directory
        skills.concat(discover_from_directory(clone_path))
      end

      # Remove duplicates (prefer working directory version if same name exists)
      seen_names = Set.new
      unique_skills = []

      skills.each do |skill|
        key = "#{skill[:type]}:#{skill[:name]}"
        unless seen_names.include?(key)
          seen_names.add(key)
          unique_skills << skill
        end
      end

      # Sort by name length first (shorter = more complete match), then alphabetically
      unique_skills.sort_by { |s| [ s[:name].length, s[:name].downcase ] }
    end

    # Extract YAML frontmatter from markdown content.
    # Public so other services (e.g., WarmSkillsCacheJob) can reuse the parsing logic.
    #
    # @param content [String] The file content
    # @return [Hash] The parsed frontmatter (empty hash if none)
    def extract_frontmatter(content)
      # Match frontmatter between --- delimiters at the start of the file
      # Allow for optional whitespace and the title coming before or after
      match = content.match(/\A(#[^\n]*\n+)?---\n(.*?)\n---/m) ||
              content.match(/\A---\n(.*?)\n---/m)

      return {} unless match

      yaml_content = match.captures.find { |c| c.present? && c.include?(":") }
      return {} unless yaml_content

      YAML.safe_load(yaml_content) || {}
    rescue Psych::SyntaxError => e
      Rails.logger.warn "Invalid YAML frontmatter: #{e.message}"
      {}
    end

    private

    # Discover skills and commands from a single directory's .claude folder
    #
    # @param base_path [String] The directory to search
    # @return [Array<Hash>] Array of skill/command hashes
    def discover_from_directory(base_path)
      return [] unless base_path.present?

      claude_dir = File.join(base_path, ".claude")
      return [] unless file_system.exists?(claude_dir) && file_system.directory?(claude_dir)

      results = []
      results.concat(discover_skills(claude_dir))
      results.concat(discover_commands(claude_dir))
      results
    end

    # Discover skills from .claude/skills/*/SKILL.md
    #
    # @param claude_dir [String] The .claude directory path
    # @return [Array<Hash>] Array of skill hashes
    def discover_skills(claude_dir)
      skills_dir = File.join(claude_dir, "skills")
      return [] unless file_system.exists?(skills_dir) && file_system.directory?(skills_dir)

      skill_dirs = file_system.glob(File.join(skills_dir, "*"))
      skill_dirs.filter_map do |skill_dir|
        next unless file_system.directory?(skill_dir)

        skill_file = File.join(skill_dir, "SKILL.md")
        next unless file_system.exists?(skill_file)

        parse_skill_file(skill_file, type: "skill")
      end
    end

    # Discover commands from .claude/commands/*.md
    #
    # @param claude_dir [String] The .claude directory path
    # @return [Array<Hash>] Array of command hashes
    def discover_commands(claude_dir)
      commands_dir = File.join(claude_dir, "commands")
      return [] unless file_system.exists?(commands_dir) && file_system.directory?(commands_dir)

      command_files = file_system.glob(File.join(commands_dir, "*.md"))
      command_files.filter_map do |command_file|
        parse_skill_file(command_file, type: "command")
      end
    end

    # Parse a skill or command file to extract name, description, and user-invocable status
    # Files have YAML frontmatter between --- delimiters
    #
    # @param file_path [String] The file path
    # @param type [String] "skill" or "command"
    # @return [Hash, nil] The parsed skill/command or nil if invalid
    def parse_skill_file(file_path, type:)
      content = file_system.read(file_path)
      return nil if content.blank?

      # Extract frontmatter (between --- delimiters)
      frontmatter = extract_frontmatter(content)

      # Use frontmatter name if available, otherwise derive from file/directory name
      name = frontmatter["name"]
      if name.blank?
        name = if type == "skill"
          File.basename(File.dirname(file_path))
        else
          File.basename(file_path, ".md")
        end
      end

      # Get description from frontmatter
      description = frontmatter["description"]

      # If no frontmatter description, try to extract from first heading or paragraph
      if description.blank?
        description = extract_description_from_content(content)
      end

      # Check if skill is user-invocable (defaults to false - skills must opt-in)
      # The "user-invocable" key uses a hyphen in YAML frontmatter
      user_invocable = frontmatter.fetch("user-invocable", false)

      {
        name: name,
        description: description || "",
        type: type,
        user_invocable: user_invocable
      }
    rescue => e
      Rails.logger.error "Error parsing skill file #{file_path}: #{e.message}"
      nil
    end

    # Extract a description from content if frontmatter doesn't have one
    # Looks for the first paragraph after headings
    #
    # @param content [String] The file content
    # @return [String, nil] The extracted description
    def extract_description_from_content(content)
      # Remove frontmatter
      content_without_frontmatter = content.sub(/\A(#[^\n]*\n+)?---\n.*?\n---\n*/m, "")
                                           .sub(/\A---\n.*?\n---\n*/m, "")

      # Find first non-heading paragraph
      lines = content_without_frontmatter.lines
      paragraph_lines = []
      in_paragraph = false

      lines.each do |line|
        stripped = line.strip
        next if stripped.empty? && !in_paragraph
        break if stripped.empty? && in_paragraph
        next if stripped.start_with?("#")
        next if stripped.start_with?("```")

        in_paragraph = true
        paragraph_lines << stripped
      end

      description = paragraph_lines.join(" ").strip
      description.presence
    end
  end
end
