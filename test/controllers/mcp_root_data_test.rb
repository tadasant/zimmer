# frozen_string_literal: true

require "test_helper"
# stub_root_data_catalog stubs AgentRootsConfig.all.
require "mocha/minitest"

# Root data end to end, the way a session reaches it: JSON-RPC over POST /mcp,
# with `tool_groups=root_data` and the `session_id` RuntimeConfigPostProcessor
# stamps on the URL — and no namespace anywhere in the request.
class McpRootDataTest < ActionDispatch::IntegrationTest
  include RootDataHelpers

  setup do
    @api_key = "test_api_key_root_data"
    ENV["API_KEYS"] = @api_key
    @headers = { "X-API-Key" => @api_key, "Content-Type" => "application/json",
                 "Accept" => "application/json, text/event-stream" }

    stub_root_data_catalog(
      root_data_root("notes-root", data_collections: default_root_data_collections),
      root_data_root("other-root", data_collections: default_root_data_collections)
    )
    @mine = Session.create!(prompt: "a", agent_runtime: "claude_code", status: :running, branch: "main",
                            git_root: "https://github.com/tadasant/zimmer.git", metadata: { "agent_root_key" => "notes-root" })
    @theirs = Session.create!(prompt: "b", agent_runtime: "claude_code", status: :running, branch: "main",
                              git_root: "https://github.com/tadasant/zimmer.git", metadata: { "agent_root_key" => "other-root" })
  end

  teardown { ENV.delete("API_KEYS") }

  def tool(name, arguments = {}, session: @mine, groups: "root_data")
    post "/mcp?tool_groups=#{groups}&session_id=#{session.id}",
         params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json,
         headers: @headers
    assert_response :success
    result = JSON.parse(response.body)["result"]
    text = result["content"].first["text"]
    [ result["isError"], (JSON.parse(text) rescue text) ]
  end

  test "a session writes and reads its own root's records, and another root sees none of them" do
    error, put = tool("put_root_record", { collection: "notes", key: "pr-1", data: { title: "keep", status: "open" } })
    assert_not error, put.inspect
    assert_equal @mine.id, put["record"]["writing_session_id"]

    _, found = tool("search_root_records", { collection: "notes", filter: { status: "open" } })
    assert_equal "notes-root", found["namespace"]
    assert_equal [ "pr-1" ], found["records"].map { |r| r["key"] }

    _, other = tool("search_root_records", { collection: "notes" }, session: @theirs)
    assert_equal "other-root", other["namespace"]
    assert_empty other["records"]

    error, _ = tool("get_root_record", { collection: "notes", id: put["record"]["id"] }, session: @theirs)
    assert error, "another root must not read a record by id"

    assert_equal 1, AgentRootRecord.where(namespace: "notes-root").count
  end

  test "the readonly group lists only the reads and refuses a write" do
    post "/mcp?tool_groups=root_data_readonly&session_id=#{@mine.id}",
         params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json, headers: @headers
    names = JSON.parse(response.body)["result"]["tools"].map { |t| t["name"] }
    assert_equal %w[list_root_collections search_root_records get_root_record], names

    post "/mcp?tool_groups=root_data_readonly&session_id=#{@mine.id}",
         params: { jsonrpc: "2.0", id: 1, method: "tools/call",
                   params: { name: "append_root_record", arguments: { collection: "runs", data: {} } } }.to_json,
         headers: @headers
    assert_equal 0, AgentRootRecord.count
  end
end
