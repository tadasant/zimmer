# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpApps::TimelineTriggerTest < ActiveSupport::TestCase
  # The test environment's store is a :null_store, which agrees with every write
  # and answers nil to every read — exactly the "index not warm yet" case. A real
  # store is needed to exercise the other one.
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @session = Session.create!(
      agent_runtime: "claude_code", prompt: "x", mcp_servers: [ "notion" ],
      git_root: "https://github.com/test/repo.git", branch: "main"
    )
    AppSetting.create!(mcp_apps_enabled: true, mcp_apps_allowed_servers: [ "notion" ])
  end

  teardown do
    Rails.cache = @original_cache
  end

  def item(tool_name: "mcp__notion__open_panel", type: OpenTranscript::Types::TOOL_CALL)
    { type: type, tool_name: tool_name, tool_call_id: "toolu_01", transcript_index: 3 }
  end

  def trigger = McpApps::TimelineTrigger.new(@session)

  test "renders a panel for an MCP tool call on an opted-in server" do
    panel = trigger.panel_for(item)

    assert_equal "notion", panel.server_name
    assert_equal "open_panel", panel.tool
    assert_equal "toolu_01", panel.tool_call_id
    assert_equal 3, panel.transcript_index
  end

  test "renders nothing for anything that is not an opted-in MCP tool call" do
    assert_nil trigger.panel_for(item(tool_name: "Bash"))
    assert_nil trigger.panel_for(item(tool_name: "mcp__context7__resolve"))
    assert_nil trigger.panel_for(item(type: OpenTranscript::Types::TOOL_RESULT))
    assert_nil trigger.panel_for(item.merge(tool_call_id: nil))
    assert_nil trigger.panel_for(item.merge(transcript_index: nil))
  end

  test "renders nothing at all when the feature is off" do
    AppSetting.current.update!(mcp_apps_enabled: false)

    refute trigger.active?
    assert_nil trigger.panel_for(item)
  end

  test "never calls the MCP server while rendering a row" do
    McpApps::ServerConnection.any_instance.expects(:client).never

    assert trigger.panel_for(item)
  end

  test "a cold index still renders the frame, because unknown is not no" do
    assert trigger.panel_for(item(tool_name: "mcp__notion__anything"))
  end

  test "a warm index suppresses the frame for a tool that has no view" do
    warm_index([
      { "name" => "open_panel", "_meta" => { "ui" => { "resourceUri" => "ui://demo/panel.html" } } },
      { "name" => "search" }
    ])

    assert trigger.panel_for(item)
    assert_nil trigger.panel_for(item(tool_name: "mcp__notion__search"))
  end

  test "reads the settings row once however many rows it is asked about" do
    AppSetting.expects(:current).once.returns(AppSetting.first)

    shared = trigger
    5.times { shared.panel_for(item) }
  end

  private

  # Write the cache the way ToolIndex would, so the trigger sees a warm index
  # without anything having gone over the network.
  def warm_index(tools)
    connection = McpApps::ServerConnection.new(@session, "notion")
    index = McpApps::ToolIndex.new(connection)
    Rails.cache.write(index.send(:cache_key), tools)
  end
end
