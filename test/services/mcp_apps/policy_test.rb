# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpApps::PolicyTest < ActiveSupport::TestCase
  include McpAppsSettingsHelpers

  test "a deployment that has decided nothing renders nothing" do
    refute McpApps::Policy.enabled?
    assert_empty McpApps::Policy.allowed_servers
    refute McpApps::Policy.allows?("notion")
  end

  test "the master switch alone is not enough" do
    enable_mcp_apps(enabled: true, servers: [])

    assert McpApps::Policy.enabled?
    refute McpApps::Policy.allows?("notion"), "no server has been opted in"
  end

  test "an opted-in server without the master switch is still off" do
    enable_mcp_apps(enabled: false)

    refute McpApps::Policy.allows?("notion")
  end

  test "both together allow exactly the named server" do
    enable_mcp_apps

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
    enable_mcp_apps
    AppSetting.stubs(:current).returns(AppSetting::NULL)

    refute McpApps::Policy.enabled?
    refute McpApps::Policy.allows?("notion")
  end
end
