# frozen_string_literal: true

require "test_helper"

# Covers McpToolSearchExtension's spawn-env contribution. Lives with the
# extension so it is removed along with app/extensions/mcp_tool_search/.
class McpToolSearchExtensionTest < ActiveSupport::TestCase
  setup { AppSetting.delete_all }

  def enable(on)
    AppSetting.editable.tap { |s| s.set_extension_enabled("mcp_tool_search", on); s.save! }
  end

  test "contributes ENABLE_TOOL_SEARCH=true for claude_code" do
    ext = McpToolSearchExtension.new
    assert_equal({ "ENABLE_TOOL_SEARCH" => "true" }, ext.spawn_env_contribution(runtime: "claude_code"))
  end

  test "contributes nothing for other runtimes" do
    ext = McpToolSearchExtension.new
    assert_equal({}, ext.spawn_env_contribution(runtime: "codex"))
    assert_equal({}, ext.spawn_env_contribution({}))
  end

  test "registry surfaces the contribution only when enabled" do
    enable(false)
    assert_equal({}, Zimmer::ExtensionRegistry.spawn_env_contributions(runtime: "claude_code"))

    enable(true)
    assert_equal(
      { "ENABLE_TOOL_SEARCH" => "true" },
      Zimmer::ExtensionRegistry.spawn_env_contributions(runtime: "claude_code")
    )
  end
end
