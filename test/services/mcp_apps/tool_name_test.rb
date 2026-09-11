# frozen_string_literal: true

require "test_helper"

class McpApps::ToolNameTest < ActiveSupport::TestCase
  SERVERS = %w[notion zimmer zimmer-sessions remote-fs-screenshots].freeze

  def parse(name, servers: SERVERS)
    McpApps::ToolName.parse(name, servers: servers)
  end

  test "splits a plain mcp tool name" do
    parsed = parse("mcp__notion__search")

    assert_equal "notion", parsed.server
    assert_equal "search", parsed.tool
  end

  test "prefers the longest matching server so a prefix does not steal the name" do
    parsed = parse("mcp__zimmer-sessions__get_session")

    assert_equal "zimmer-sessions", parsed.server
    assert_equal "get_session", parsed.tool
  end

  test "a tool name containing the delimiter stays whole" do
    parsed = parse("mcp__remote-fs-screenshots__remote-filesystem-tmp-public__upload_file")

    assert_equal "remote-fs-screenshots", parsed.server
    assert_equal "remote-filesystem-tmp-public__upload_file", parsed.tool
  end

  test "matches the sanitized server name a Codex rollout writes" do
    # Codex rewrites every character outside [A-Za-z0-9_-] to `_` before it
    # exposes the tool, so the transcript name and the catalog name differ.
    parsed = parse("mcp__remote_fs_screenshots__upload", servers: [ "remote.fs.screenshots" ])

    assert_equal "remote.fs.screenshots", parsed.server
    assert_equal "upload", parsed.tool
  end

  test "a non-mcp tool, an unattached server, and an empty tool are all nothing" do
    assert_nil parse("Bash")
    assert_nil parse("mcp__figma__get_file")
    assert_nil parse("mcp__notion__")
    assert_nil parse(nil)
  end
end
