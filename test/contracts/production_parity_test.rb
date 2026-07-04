# frozen_string_literal: true

require "test_helper"

# Contract tests for production/test environment parity
#
# Historical context:
# 15% of production bugs were caused by environment/configuration mismatches:
#
# Bug Type 1: Test-Only Class References in Production Code
# - Commit 58d8229e: Production code referenced MockFileSystemAdapter which
#   only exists in test/support/. Tests passed but production crashed.
#
# Bug Type 2: ENV Variable Truthiness
# - Commit acf94a27: Setting SOLID_QUEUE_IN_PUMA=false didn't disable the
#   feature because "false" string is truthy in Ruby. (Note: SolidQueue was
#   replaced with GoodJob in Nov 2024, but the lesson still applies.)
#
# These bugs are particularly insidious because:
# 1. All tests pass (test environment has the classes/values)
# 2. CI passes (same test environment)
# 3. Bug only manifests in production or during manual testing
# 4. Often causes complete application failure (not partial degradation)
#
class ProductionParityTest < ActiveSupport::TestCase
  # Test-only classes that exist in test/support/ but not in production
  # These MUST NOT be referenced in production code (app/ directory)
  TEST_ONLY_CLASSES = %w[
    MockFileSystemAdapter
    MockProcessManager
    MockClaudeCliAdapter
    MockCodexRuntimeAdapter
    MockFileSystemAdapterTest
    MockRateLimitTracker
  ].freeze

  # ENV variables that should use explicit comparison, not implicit truthiness
  # Pattern: `if ENV["VAR"]` is dangerous because "false" string is truthy
  # Use: `if ENV["VAR"] == "true"` instead
  #
  # Allowlist for ENV checks that are safe to use implicit truthiness:
  # - Existence checks for optional paths (e.g., ENV["PIDFILE"])
  # - Fetch with defaults (e.g., ENV.fetch("VAR", default))
  #
  # Note: SOLID_QUEUE_IN_PUMA was removed when we migrated from SolidQueue to
  # GoodJob. The test remains to catch any new boolean ENV vars that are added.
  BOOLEAN_ENV_VARS = %w[].freeze

  test "production code does not reference test-only classes" do
    production_files = Dir.glob(Rails.root.join("app/**/*.rb"))

    violations = []
    production_files.each do |file|
      content = File.read(file)
      content.each_line.with_index(1) do |line, line_num|
        # Remove inline comments before checking (split on # and take code portion)
        # This handles both full comment lines and inline comments like:
        #   value = something  # Don't use MockFileSystemAdapter here
        code_part = line.split("#").first || ""
        next if code_part.strip.empty?

        TEST_ONLY_CLASSES.each do |klass|
          # Match whole word to avoid false positives
          # (e.g., "MockFileSystemAdapter" but not "SomeMockFileSystemAdapterThing")
          if code_part.match?(/\b#{Regexp.escape(klass)}\b/)
            violations << "#{relative_path(file)}:#{line_num} references test-only class '#{klass}': #{line.strip}"
          end
        end
      end
    end

    assert_empty violations, format_violations(
      "Production code references test-only classes",
      violations,
      "Remove references to test-only classes from production code.\n" \
      "These classes only exist in test/support/ and will cause NameError in production."
    )
  end

  test "config files use explicit ENV comparison not truthiness for boolean vars" do
    config_files = collect_config_files

    violations = []
    config_files.each do |file|
      next unless File.exist?(file)

      content = File.read(file)

      BOOLEAN_ENV_VARS.each do |var_name|
        # Check for implicit truthiness patterns (dangerous):
        # - if ENV["VAR"]
        # - unless ENV["VAR"]
        # - ENV["VAR"] && ...
        # - ... || ENV["VAR"]
        # - ENV["VAR"] ? ... : ...  (ternary operator)
        #
        # Allow explicit comparison (safe):
        # - if ENV["VAR"] == "true"
        # - if ENV["VAR"] != "false"
        # - unless ENV["VAR"] == "true"

        content.each_line.with_index(1) do |line, line_num|
          next unless line.include?("ENV[") && line.include?(var_name)

          # Skip lines with explicit comparison (== or !=)
          next if line.match?(/ENV\[["']#{var_name}["']\]\s*[!=]=/)

          # Check for implicit truthiness patterns
          if line.match?(/(?:if|unless|&&|\|\|)\s*ENV\[["']#{var_name}["']\]/) ||
             line.match?(/ENV\[["']#{var_name}["']\]\s*(?:&&|\|\||\?)/)
            violations << "#{relative_path(file)}:#{line_num} uses implicit truthiness for ENV[\"#{var_name}\"]: #{line.strip}"
          end
        end
      end
    end

    assert_empty violations, format_violations(
      "Config files use implicit ENV truthiness for boolean variables",
      violations,
      "Use explicit comparison: ENV[\"VAR\"] == \"true\" instead of if ENV[\"VAR\"]\n" \
      "The string \"false\" is truthy in Ruby, causing unexpected behavior."
    )
  end

  test "test-only classes list is up to date with test/support" do
    # Find all class definitions in test/support/
    support_files = Dir.glob(Rails.root.join("test/support/**/*.rb"))

    defined_classes = []
    support_files.each do |file|
      content = File.read(file)
      # Match class definitions
      content.scan(/^class\s+(\w+)/).each do |match|
        defined_classes << match[0]
      end
    end

    # Filter to only Mock* classes (the ones most likely to cause issues)
    mock_classes = defined_classes.select { |klass| klass.start_with?("Mock") }

    missing_from_list = mock_classes - TEST_ONLY_CLASSES
    extra_in_list = TEST_ONLY_CLASSES.select { |k| k.start_with?("Mock") } - mock_classes

    issues = []
    if missing_from_list.any?
      issues << "Mock classes in test/support/ not in TEST_ONLY_CLASSES: #{missing_from_list.join(', ')}"
    end
    if extra_in_list.any?
      issues << "TEST_ONLY_CLASSES entries no longer exist in test/support/: #{extra_in_list.join(', ')}"
    end

    assert_empty issues, issues.join("\n") + "\n\nUpdate TEST_ONLY_CLASSES in #{__FILE__}"
  end

  private

  def collect_config_files
    files = []
    files += Dir.glob(Rails.root.join("config/**/*.rb"))
    files << Rails.root.join("config.ru")
    files << Rails.root.join("Rakefile")
    files
  end

  def relative_path(file)
    file.to_s.sub(Rails.root.to_s + "/", "")
  end

  def format_violations(title, violations, resolution)
    message = "\n#{title}:\n\n"
    violations.each { |v| message += "  • #{v}\n" }
    message += "\nResolution:\n#{resolution}"
    message
  end
end
