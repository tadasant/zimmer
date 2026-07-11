# frozen_string_literal: true

require "test_helper"
require "path_sanitizer"

class PathSanitizerTest < ActiveSupport::TestCase
  test "sanitizes forward slashes" do
    assert_equal "-Users-admin-projects", PathSanitizer.sanitize("/Users/admin/projects")
  end

  test "sanitizes dots" do
    assert_equal "-config--agent-orchestrator", PathSanitizer.sanitize(".config/.agent-orchestrator")
  end

  test "sanitizes underscores" do
    assert_equal "test-file-name", PathSanitizer.sanitize("test_file_name")
  end

  test "sanitizes all special characters together" do
    path = "/Users/admin/.zimmer/clones/pulsemcp-main-1764273034-168756be"
    expected = "-Users-admin--zimmer-clones-pulsemcp-main-1764273034-168756be"
    assert_equal expected, PathSanitizer.sanitize(path)
  end

  test "handles consecutive special characters" do
    assert_equal "--foo--bar--", PathSanitizer.sanitize("/.foo/_bar/.")
  end

  test "handles Pathname objects" do
    pathname = Pathname.new("/Users/admin/.config")
    assert_equal "-Users-admin--config", PathSanitizer.sanitize(pathname)
  end

  test "returns nil for nil input" do
    assert_nil PathSanitizer.sanitize(nil)
  end

  test "returns nil for empty string" do
    assert_nil PathSanitizer.sanitize("")
  end

  test "handles string with only special characters" do
    assert_equal "-----", PathSanitizer.sanitize("/._/_")
  end
end
