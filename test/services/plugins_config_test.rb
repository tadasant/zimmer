# frozen_string_literal: true

require "test_helper"

class PluginsConfigTest < ActiveSupport::TestCase
  setup do
    PluginsConfig.reload!
  end

  test "all returns array of plugins" do
    plugins = PluginsConfig.all

    assert plugins.is_a?(Array)
    assert plugins.any?, "Expected at least one plugin in the catalog"
  end

  test "find returns plugin by id" do
    plugin = PluginsConfig.find("ci-workflow")

    assert_not_nil plugin
    assert_equal "ci-workflow", plugin.id
    assert_equal "CI Workflow", plugin.title
  end

  test "find returns nil for unknown plugin" do
    assert_nil PluginsConfig.find("nonexistent-plugin")
  end

  test "find! raises PluginNotFoundError for unknown plugin" do
    assert_raises(PluginsConfig::PluginNotFoundError) do
      PluginsConfig.find!("nonexistent-plugin")
    end
  end

  test "exists? returns true for known plugin" do
    assert PluginsConfig.exists?("ci-workflow")
  end

  test "exists? returns false for unknown plugin" do
    refute PluginsConfig.exists?("nonexistent-plugin")
  end

  test "ids returns array of plugin ids" do
    ids = PluginsConfig.ids

    assert ids.is_a?(Array)
    assert_includes ids, "ci-workflow"
  end

  test "plugin has correct attributes" do
    plugin = PluginsConfig.find("ci-workflow")

    assert_equal "ci-workflow", plugin.id
    assert_equal "CI Workflow", plugin.title
    assert_equal "1.0.0", plugin.version
    assert_includes plugin.skills, "wait-for-ci"
    assert_includes plugin.hooks, "git-push-ci-reminder"
    assert_includes plugin.keywords, "ci"
  end

  test "plugin to_h includes all fields" do
    plugin = PluginsConfig.find("ci-workflow")
    hash = plugin.to_h

    assert_equal "ci-workflow", hash[:id]
    assert_equal "CI Workflow", hash[:title]
    assert_includes hash.keys, :description
    assert_includes hash.keys, :version
    assert_includes hash.keys, :skills
    assert_includes hash.keys, :mcp_servers
    assert_includes hash.keys, :hooks
    assert_includes hash.keys, :keywords
  end

  test "plugin exposes mcp_servers when declared in catalog" do
    plugin = PluginsConfig.find("screenshots-videos")

    assert_not_nil plugin, "expected screenshots-videos plugin to exist in the catalog"
    assert_includes plugin.mcp_servers, "playwright-custom"
    assert_includes plugin.mcp_servers, "remote-fs-screenshots"
  end

  test "plugin mcp_servers defaults to empty array when not declared" do
    plugin = PluginsConfig.find("ci-workflow")

    assert_equal [], plugin.mcp_servers
  end

  test "reload! clears cache and reloads" do
    original_count = PluginsConfig.all.size
    PluginsConfig.reload!
    assert_equal original_count, PluginsConfig.all.size
  end
end
