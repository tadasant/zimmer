# frozen_string_literal: true

# PathSanitizer provides utilities for sanitizing filesystem paths to match
# Claude CLI's naming conventions for transcript and cache directories.
#
# Claude CLI sanitizes working directory paths by replacing '/', '.', and '_'
# characters with '-' to create safe directory names. This module centralizes
# that logic to ensure consistency across the codebase.
#
# @example
#   PathSanitizer.sanitize("/Users/admin/.zimmer/clones/repo_name")
#   # => "-Users-admin--zimmer-clones-repo-name"
module PathSanitizer
  # Returns the base directory for Claude CLI cache files.
  # This differs between macOS and Linux:
  # - macOS: ~/Library/Caches/claude-cli-nodejs
  # - Linux: ~/.cache/claude-cli-nodejs
  #
  # @return [String] The platform-appropriate cache directory path
  #
  # @example
  #   PathSanitizer.cache_base
  #   # => "/home/rails/.cache/claude-cli-nodejs" (on Linux)
  #   # => "/Users/admin/Library/Caches/claude-cli-nodejs" (on macOS)
  def self.cache_base
    home_dir = File.expand_path("~")

    if RUBY_PLATFORM.include?("darwin")
      File.join(home_dir, "Library", "Caches", "claude-cli-nodejs")
    else
      File.join(home_dir, ".cache", "claude-cli-nodejs")
    end
  end

  # Sanitizes a path by replacing '/', '.', and '_' with '-'
  # This matches Claude CLI's path sanitization behavior for transcript
  # and cache directory naming.
  #
  # @param path [String, Pathname] The path to sanitize
  # @return [String] The sanitized path with special characters replaced
  # @return [nil] If path is nil or empty
  #
  # @example
  #   PathSanitizer.sanitize("/Users/admin/.config/test_file")
  #   # => "-Users-admin--config-test-file"
  def self.sanitize(path)
    return nil unless path
    return nil if path.to_s.empty?

    path.to_s.gsub(/[\/._]/, "-")
  end
end
