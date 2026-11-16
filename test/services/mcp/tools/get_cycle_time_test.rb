# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::GetCycleTimeTest < ActiveSupport::TestCase
  include CycleTimeFixtures

  setup do
    @tool = Mcp::Tools::GetCycleTime.new(context: Mcp::Context.new(tool_groups: "sessions_readonly", base_url: "https://zimmer.example"))
  end

  test "is registered read-only in sessions, and not in self_session" do
    assert_includes Mcp::Registry.tools_for([ "sessions_readonly" ]).map(&:tool_name), "get_cycle_time"
    assert_not_includes Mcp::Registry.tools_for([ "self_session" ]).map(&:tool_name), "get_cycle_time"
  end

  test "answers where yesterday's runs were bottlenecked in one call" do
    yesterday = Date.current - 1
    create_cycle_time_row(finished_at: yesterday.in_time_zone.noon, totals: { "inference" => 600, "wait_ci" => 2400, "local_io" => 300 }, title: "A")
    create_cycle_time_row(finished_at: yesterday.in_time_zone.noon + 1.hour, totals: { "inference" => 400, "wait_merge_gate" => 900 }, title: "B")
    create_cycle_time_row(finished_at: 3.days.ago, totals: { "wait_human" => 9999 }, title: "Older")
    create_cycle_time_row(finished_at: yesterday.in_time_zone.noon, totals: { "inference" => 5 }, eligible: false, reason: "human_archive")

    result = @tool.call("from" => yesterday.iso8601, "to" => yesterday.iso8601)

    assert_equal 2, result[:eligible_hierarchies]
    assert_equal({ "human_archive" => 1 }, result[:ineligible_hierarchies])
    assert_in_delta 4600, result[:wall_seconds]
    assert_equal "wait_ci", result[:top_wait_categories].first[:category]
    assert_in_delta 2400.0 / 4600, result[:top_wait_categories].first[:share], 0.001
    assert_equal "wait_ci", result[:top_segments].first["category"]
    assert_equal "A", result[:top_segments].first["task"]
    assert_equal %w[A B], result[:hierarchies].map { |h| h[:title] }
    assert_in_delta 4600, result[:categories].sum { |c| c[:seconds] }
    assert_match "https://zimmer.example/cycle_times?", result[:page_url]
  end

  test "filters by agent root" do
    create_cycle_time_row(finished_at: 1.hour.ago, totals: { "inference" => 10 }, agent_root: "strad")
    create_cycle_time_row(finished_at: 1.hour.ago, totals: { "inference" => 20 }, agent_root: "zimmer")

    assert_equal 1, @tool.call("agent_root" => "strad")[:eligible_hierarchies]
  end

  test "root_session_id returns one task's breakdown, segments on request" do
    row = create_cycle_time_row(finished_at: 1.hour.ago, totals: { "inference" => 10, "wait_ci" => 50 })

    brief = @tool.call("root_session_id" => row.root_session_id)
    full = @tool.call("root_session_id" => row.root_session_id, "include_segments" => true)

    assert_equal "wait_ci", brief[:top_wait_categories].first[:category]
    assert_nil brief[:sessions].first["segments"]
    assert_equal 1, full[:sessions].first["segments"].size
    assert full[:hierarchy_segments].present?
  end

  test "an unknown or non-root session explains itself" do
    parent = create_session
    child = create_session(parent_session_id: parent.id)

    error = assert_raises(Mcp::ToolError) { @tool.call("root_session_id" => child.id) }
    assert_match "not a root", error.message
    error = assert_raises(Mcp::ToolError) { @tool.call("root_session_id" => parent.id) }
    assert_match "in flight", error.message
  end
end
