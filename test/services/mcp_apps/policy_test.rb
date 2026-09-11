# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpApps::PolicyTest < ActiveSupport::TestCase
  test "a deployment that has decided nothing renders nothing" do
    refute McpApps::Policy.enabled?
    assert_empty McpApps::Policy.allowed_servers
    refute McpApps::Policy.allows?("notion")
  end

  test "the master switch alone is not enough" do
    AppSetting.create!(mcp_apps_enabled: true)

    assert McpApps::Policy.enabled?
    refute McpApps::Policy.allows?("notion"), "no server has been opted in"
  end

  test "an opted-in server without the master switch is still off" do
    AppSetting.create!(mcp_apps_enabled: false, mcp_apps_allowed_servers: [ "notion" ])

    refute McpApps::Policy.allows?("notion")
  end

  test "both together allow exactly the named server" do
    AppSetting.create!(mcp_apps_enabled: true, mcp_apps_allowed_servers: [ "notion" ])

    assert McpApps::Policy.allows?("notion")
    refute McpApps::Policy.allows?("figma")
    refute McpApps::Policy.allows?(nil)
    refute McpApps::Policy.allows?("")
  end

  test "only remote catalog servers are eligible to be opted in" do
    names = McpApps::Policy.eligible_servers.map(&:name)

    assert_includes names, "notion"
    refute_includes names, "context7", "context7 is stdio"
  end

  test "a submitted allowlist keeps only names the catalog offers as remote" do
    sanitized = McpApps::Policy.sanitize_allowlist([ "notion", "context7", "made-up", "notion" ])

    assert_equal [ "notion" ], sanitized
    assert_empty McpApps::Policy.sanitize_allowlist(nil)
  end

  test "an unreadable settings row leaves the feature off rather than on" do
    AppSetting.create!(mcp_apps_enabled: true, mcp_apps_allowed_servers: [ "notion" ])
    AppSetting.stubs(:current).returns(AppSetting::NULL)

    refute McpApps::Policy.enabled?
    refute McpApps::Policy.allows?("notion")
  end
end
