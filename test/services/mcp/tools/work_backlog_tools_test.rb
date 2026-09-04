# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

# The three backlog tools, and the things they must never do between them.
class Mcp::Tools::WorkBacklogToolsTest < ActiveSupport::TestCase
  include WorkBacklogHelpers

  setup do
    @gate = sessions(:running)
    @gate.update_columns(metadata: (@gate.metadata || {}).merge("agent_root_key" => "issue-work-gate"),
                         precedence: 100, scheduling_class: "spot")
    @context = Mcp::Context.new(tool_groups: "work_backlog", session_id: @gate.id)
    @read = Mcp::Tools::GetWorkBacklog.new(context: @context)
    @append = Mcp::Tools::AppendWorkBacklogItem.new(context: @context)
    @pull = Mcp::Tools::PullWorkBacklogItems.new(context: @context)
  end

  # --- read -----------------------------------------------------------------

  test "read returns the queue in rank order with positions, counts and bands" do
    backlog_item(key: "zimmer#1", cost: "medium", precedence: 3000)
    backlog_item(key: "zimmer#2", cost: "small", precedence: 6000)
    backlog_item(key: "zimmer#3", cost: "small", precedence: 5990)

    output = @read.call({})

    assert_equal [ "zimmer#2", "zimmer#3", "zimmer#1" ], output[:items].map { |i| i[:key] }
    assert_equal [ 1, 2, 3 ], output[:items].map { |i| i[:position] }
    assert_equal 3, output[:total_matching]
    assert_equal 3, output.dig(:counts, :queued)
    assert_equal 0, output.dig(:counts, :in_flight)
    assert_nil output[:next_offset]
    assert_equal 3, output.dig(:ranking, :bands).size
  end

  test "read filters and pages, keeping whole-queue positions" do
    backlog_item(key: "zimmer#1", cost: "small", precedence: 6000)
    backlog_item(key: "strad#2", cost: "small", precedence: 5990, surface: "strad", repo: "tadasant/strad")

    filtered = @read.call("surface" => "strad")
    assert_equal [ "strad#2" ], filtered[:items].map { |i| i[:key] }
    assert_equal [ 2 ], filtered[:items].map { |i| i[:position] }

    page = @read.call("limit" => 1)
    assert_equal 1, page[:returned]
    assert_equal 1, page[:next_offset]
    assert_equal [ "strad#2" ], @read.call("limit" => 1, "offset" => 1)[:items].map { |i| i[:key] }
  end

  test "read defaults to the queue, shows history on request, and rejects a filter outside the vocabulary" do
    item = backlog_item(key: "zimmer#1")
    item.mark_started!(session: sessions(:archived), by: nil)

    assert_equal 0, @read.call({})[:total_matching]
    history = @read.call("status" => "all", "key" => "zimmer#1")
    assert_equal 1, history[:total_matching]
    assert_nil history[:items].first[:position]
    assert_equal sessions(:archived).id, history[:items].first[:started_session_id]

    assert_raises(Mcp::ToolError) { @read.call("status" => "done") }
    assert_raises(Mcp::ToolError) { @read.call("limit" => 0) }
    assert_raises(Mcp::ToolError) { @read.call("offset" => "abc") }
    assert_raises(Mcp::ToolError) { @read.call("pinned" => "maybe") }
    assert_equal WorkBacklog::Filters::MAX_LIMIT, WorkBacklog::Filters.new("limit" => 10_000).limit
  end

  # --- append ---------------------------------------------------------------

  test "append stamps the writing session and added_by from the connection, and places by the rules" do
    backlog_item(cost: "small", precedence: 6000)

    output = @append.call(append_attributes(key: "zimmer#7", "gate_session" => "https://zimmer.example.com/sessions/3"))

    assert_equal "appended", output[:result]
    assert_equal 2, output[:position]
    assert_equal 5990, output[:precedence]
    item = WorkBacklogItem.find_by!(key: "zimmer#7")
    assert_equal @gate.id, item.writing_session_id
    assert_equal "issue-work-gate", item.added_by
    assert_equal WorkBacklogItem::MCP, item.added_via
    assert_equal "https://zimmer.example.com/sessions/3", item.gate_session_url
    assert_not item.pinned
  end

  test "append is idempotent on key" do
    @append.call(append_attributes(key: "zimmer#7"))
    output = @append.call(append_attributes(key: "zimmer#7"))

    assert_equal "already_queued", output[:result]
    assert_equal 1, WorkBacklogItem.count
  end

  test "append has no way to name its author, place the item, or mint an issueless item" do
    properties = Mcp::Tools::AppendWorkBacklogItem.input_schema.to_h.deep_stringify_keys["properties"].keys
    %w[writing_session_id added_by precedence pinned prompt].each do |forbidden|
      assert_not_includes properties, forbidden
    end

    %w[writing_session_id added_by precedence pinned prompt].each do |forbidden|
      error = assert_raises(Mcp::ToolError) { @append.call(append_attributes(forbidden => "x")) }
      assert_match(/cannot be set from this tool/, error.message)
    end

    error = assert_raises(Mcp::ToolError) { @append.call(append_attributes("issue_url" => "")) }
    assert_match(/issue_url is required/, error.message)
    assert_equal 0, WorkBacklogItem.count
  end

  test "append rejects a malformed item and writes nothing" do
    error = assert_raises(Mcp::ToolError) { @append.call(append_attributes("estimated_cost" => "huge")) }

    assert_match(/nothing was written/, error.message)
    assert_equal 0, WorkBacklogItem.count
  end

  test "append works for a connection with no session: writer nil, added_by mcp" do
    tool = Mcp::Tools::AppendWorkBacklogItem.new(context: Mcp::Context.new(tool_groups: "work_backlog"))

    output = tool.call(append_attributes(key: "zimmer#8"))

    assert_nil output.dig(:item, :writing_session_id)
    assert_equal "mcp", output.dig(:item, :added_by)
  end

  # --- pull -----------------------------------------------------------------

  test "pull starts the top N as spot sessions under the calling session and records them" do
    backlog_item(key: "zimmer#1", precedence: 6000)
    backlog_item(key: "zimmer#2", precedence: 5990)

    output = assert_difference("Session.count", 2) { @pull.call("count" => 2) }

    assert_equal [ "zimmer#1", "zimmer#2" ], output[:started].map { |s| s.dig(:item, :key) }
    session = output[:started].first[:session]
    assert_equal "spot", session[:scheduling_class]
    assert_equal @gate.id, session[:parent_session_id]
    assert_equal 102, session[:precedence]
    assert_match %r{/sessions/#{session[:id]}\z}, session[:url]
    assert_equal @gate.id, output[:pulled_by_session_id]
    assert_equal 0, output.dig(:queue, :queued)
    assert_equal 2, output.dig(:queue, :in_flight)
    assert_equal @gate.id, WorkBacklogItem.find_by(key: "zimmer#1").started_by_session_id
  end

  test "pull by keys, with dead items removed for a mechanical reason" do
    backlog_item(key: "zimmer#1", precedence: 6000)
    backlog_item(key: "zimmer#2", precedence: 5990)

    output = @pull.call("keys" => [ "zimmer#2" ], "dead" => [ { "key" => "zimmer#1", "reason" => "trust_failed" } ])

    assert_equal [ "zimmer#2" ], output[:started].map { |s| s.dig(:item, :key) }
    assert_equal [ { key: "zimmer#1", reason: "trust_failed" } ], output[:removed].map { |r| r.slice(:key, :reason) }
    assert_equal "session:#{@gate.id}", WorkBacklogItem.find_by(key: "zimmer#1").removed_by
  end

  test "pull refuses a discretionary removal and a key that is not queued" do
    backlog_item(key: "zimmer#1")

    error = assert_raises(Mcp::ToolError) { @pull.call("dead" => [ { "key" => "zimmer#1", "reason" => "boring" } ]) }
    assert_match(/Nothing was pulled/, error.message)

    assert_raises(Mcp::ToolError) { @pull.call("keys" => [ "zimmer#404" ]) }
    assert WorkBacklogItem.find_by(key: "zimmer#1").queued?
  end

  test "a restricted connection can only pull if it may spawn the router root" do
    backlog_item(key: "zimmer#1")
    restricted = Mcp::Tools::PullWorkBacklogItems.new(context: Mcp::Context.new(tool_groups: "work_backlog", allowed_agent_roots: "zimmer"))

    error = assert_raises(Mcp::ToolError) { restricted.call("count" => 1) }
    assert_match(/restricted/, error.message)
    assert WorkBacklogItem.find_by(key: "zimmer#1").queued?
  end

  # allowed_agent_roots is baked into a session's .mcp.json when it spawns, so a
  # groomer started before the zimmer-router → zimmer-orchestrator rename is
  # still carrying the old name on disk. Both names denote the same root, so
  # either one has to grant the pull.
  AgentRootsConfig::ROUTER_ROOT_NAMES.each do |granted|
    test "a restricted connection granted #{granted} may pull" do
      backlog_item(key: "zimmer#1")
      restricted = Mcp::Tools::PullWorkBacklogItems.new(
        context: Mcp::Context.new(tool_groups: "work_backlog", allowed_agent_roots: granted, session_id: @gate.id)
      )

      result = restricted.call("count" => 1)

      assert_equal [ "zimmer#1" ], result[:started].map { |s| s.dig(:item, :key) }
    end
  end

  # --- the human-only operations have no MCP path ----------------------------

  test "no tool anywhere pins, hand-places, removes by judgement, or promotes to priority" do
    names = Mcp::Registry::ALL_TOOLS.map { |d| d.klass.constantize.tool_name }
    assert_empty names.grep(/pin|place|remove|start_now|promote/), "a human-only backlog operation is registered as a tool"

    Mcp::Registry::ALL_TOOLS.select(&:write?).map { |d| d.klass.constantize }.each do |klass|
      properties = klass.input_schema.to_h.deep_stringify_keys.fetch("properties", {}).keys
      assert_empty properties & %w[pinned precedence_override scheduling_class_override],
                   "#{klass.tool_name} accepts a hand-placement parameter"
    end

    # `dead` is the one removal an agent may make, and its reason is an enum of
    # observed facts, not free text.
    dead = Mcp::Tools::PullWorkBacklogItems.input_schema.to_h.deep_stringify_keys.dig("properties", "dead", "items", "properties", "reason")
    assert_equal WorkBacklogItem::MECHANICAL_REMOVAL_REASONS, dead["enum"]
  end
end
