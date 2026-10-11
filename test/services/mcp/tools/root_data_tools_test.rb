# frozen_string_literal: true

require "test_helper"
# stub_root_data_catalog stubs AgentRootsConfig.all.
require "mocha/minitest"

# The six root_data tools, end to end through Mcp::Tool.call — the seam the MCP
# endpoint uses — with the namespace coming only from the connection.
class Mcp::Tools::RootDataToolsTest < ActiveSupport::TestCase
  include RootDataHelpers

  setup do
    stub_root_data_catalog(root_data_root("zimmer", data_collections: default_root_data_collections))
    @session = root_data_session("zimmer")
    @context = Mcp::Context.new(tool_groups: "root_data", session_id: @session.id)
  end

  def call(tool, context: @context, **args)
    response = tool.call(server_context: context, **args)
    text = response.content.first[:text]
    [ response.error?, (JSON.parse(text) rescue text) ]
  end

  test "put, get, search, list and delete round-trip in the session's root's namespace" do
    error, put = call(Mcp::Tools::PutRootRecord, collection: "notes", key: "pr-7", data: { title: "Hold", status: "open" })
    assert_not error, put.inspect
    assert put["created"]
    assert_equal @session.id, put["record"]["writing_session_id"]

    _, appended = call(Mcp::Tools::AppendRootRecord, collection: "runs", data: { outcome: "green" })
    assert appended["id"]

    _, got = call(Mcp::Tools::GetRootRecord, collection: "notes", key: "pr-7")
    assert_equal({ "title" => "Hold", "status" => "open" }, got["data"])

    _, found = call(Mcp::Tools::SearchRootRecords, collection: "notes", filter: { status: "open" })
    assert_equal "zimmer", found["namespace"]
    assert_equal [ "pr-7" ], found["records"].map { |r| r["key"] }

    _, listed = call(Mcp::Tools::ListRootCollections)
    notes = listed["collections"].find { |c| c["name"] == "notes" }
    assert notes["declared"]
    assert_equal 1, notes["records"]
    assert_equal 30, notes["retention_days"]

    _, deleted = call(Mcp::Tools::DeleteRootRecord, collection: "notes", key: "pr-7")
    assert deleted["deleted"]
    error, missing = call(Mcp::Tools::GetRootRecord, collection: "notes", key: "pr-7")
    assert error
    assert_match(/No record/, missing)
  end

  test "no tool accepts a namespace argument" do
    Mcp::Registry::ALL_TOOLS.select { |d| d.group == "root_data" }.each do |definition|
      properties = definition.klass.constantize.input_schema.to_h[:properties] || {}
      assert_not_includes properties.keys.map(&:to_s), "namespace", "#{definition.klass} must not take a namespace"
    end
  end

  test "refusals come back as tool errors the agent can read" do
    error, message = call(Mcp::Tools::AppendRootRecord, collection: "undeclared", data: { a: 1 })
    assert error
    assert_match(/not declared/, message)

    error, message = call(Mcp::Tools::AppendRootRecord, collection: "runs", data: { a: "x\u0000" })
    assert error, "a NUL must come back as a tool error, not a JSON-RPC internal error"
    assert_match(/NUL character/, message)

    error, message = call(Mcp::Tools::ListRootCollections, context: Mcp::Context.new(tool_groups: "root_data"))
    assert error
    assert_match(/names no calling session/, message)
    assert_equal 0, AgentRootRecord.count
  end

  test "the readonly group carries the three reads and none of the writes" do
    full = Mcp::Registry.tools_for(Mcp::Registry.parse_groups("root_data")).map(&:tool_name)
    readonly = Mcp::Registry.tools_for(Mcp::Registry.parse_groups("root_data_readonly")).map(&:tool_name)
    unscoped = Mcp::Registry.tools_for(Mcp::Registry.parse_groups(nil)).map(&:tool_name)

    assert_equal %w[list_root_collections search_root_records get_root_record put_root_record append_root_record delete_root_record], full
    assert_equal %w[list_root_collections search_root_records get_root_record], readonly
    assert_empty unscoped & full, "root_data is opt-in: the unscoped surface must not carry it"
  end
end
