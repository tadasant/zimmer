# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpApps::ToolIndexTest < ActiveSupport::TestCase
  include McpAppsSettingsHelpers

  TOOLS = [
    { "name" => "open_panel", "title" => "Open panel", "description" => "Opens it",
      "inputSchema" => { "type" => "object", "properties" => { "note" => { "type" => "string" } } },
      "_meta" => { "io.modelcontextprotocol/ui" => { "resourceUri" => "ui://demo/panel.html" } } },
    { "name" => "roll_dice", "_meta" => { "ui" => { "visibility" => [ "app" ] } } },
    { "name" => "search", "annotations" => { "title" => "Search" } },
    { "name" => "", "_meta" => {} },
    "not a tool"
  ].freeze

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    @session = Session.create!(
      agent_runtime: "claude_code", prompt: "x", mcp_servers: [ "notion" ],
      git_root: "https://github.com/test/repo.git", branch: "main"
    )
    enable_mcp_apps

    @client = mock("client")
    @connection = McpApps::ServerConnection.new(@session, "notion")
    @connection.stubs(:client).returns(@client)
  end

  teardown do
    Rails.cache = @original_cache
  end

  def index = McpApps::ToolIndex.new(@connection)

  test "reads both spellings of the ui metadata and skips junk entries" do
    @client.expects(:tools_list).returns(TOOLS)

    entries = index.entries

    assert_equal %w[open_panel roll_dice search], entries.keys.sort
    assert entries["open_panel"].view?
    refute entries["open_panel"].app_callable?
    assert entries["roll_dice"].app_callable?
    refute entries["roll_dice"].view?
    refute entries["search"].view?
  end

  test "titles fall back through title, annotations.title, then the name itself" do
    @client.expects(:tools_list).returns(TOOLS)

    entries = index.entries

    assert_equal "Open panel", entries["open_panel"].title
    assert_equal "Search", entries["search"].title
    assert_equal "roll_dice", entries["roll_dice"].title
  end

  test "to_tool is a real MCP Tool, inputSchema included even when the server omits one" do
    @client.expects(:tools_list).returns(TOOLS)

    entries = index.entries

    assert_equal({ "type" => "object", "properties" => { "note" => { "type" => "string" } } },
      entries["open_panel"].to_tool["inputSchema"])
    # The reference SDK validates this against the full Tool schema, and a view
    # whose host omits inputSchema never finishes connect().
    assert_equal({ "type" => "object", "properties" => {} }, entries["search"].to_tool["inputSchema"])
    assert_equal "", entries["search"].to_tool["description"]
  end

  test "the list is fetched once and then answered from cache" do
    @client.expects(:tools_list).once.returns(TOOLS)

    index.entries
    assert index.cached, "a second reader sees a warm index"
    assert_equal "open_panel", index.entry("open_panel").name
  end

  test "cached never fetches, and is nil until something has" do
    @client.expects(:tools_list).never

    assert_nil index.cached
  end

  test "repointing a server at another host does not serve the old host's tools" do
    @client.expects(:tools_list).returns(TOOLS)
    index.entries

    moved = McpApps::ServerConnection.new(@session, "notion")
    moved.stubs(:server).returns(stub(url: "https://somewhere-else.example/mcp", type: "streamable-http"))

    assert_nil McpApps::ToolIndex.new(moved).cached
  end

  test "a tool whose ui metadata is not a ui:// uri does not count as a view" do
    @client.expects(:tools_list).returns([
      { "name" => "sneaky", "_meta" => { "ui" => { "resourceUri" => "https://evil.example/panel.html" } } }
    ])

    refute index.entry("sneaky").view?
  end
end
