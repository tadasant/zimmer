# frozen_string_literal: true

require "test_helper"

# The `operating_costs` tool group: two reads and the write, the same objects the
# Costs page and the REST API use.
class Mcp::Tools::OperatingCostsToolsTest < ActiveSupport::TestCase
  include OperatingCostFixtures

  def context(groups = "operating_costs", session_id: nil)
    Mcp::Context.new(tool_groups: groups, base_url: "https://zimmer.example.com", session_id: session_id)
  end

  def call(tool, args, **opts)
    response = tool.call(server_context: context(**opts), **args.symbolize_keys)
    text = response.content.first[:text]
    raise Mcp::ToolError, text if response.error?

    JSON.parse(text)
  end

  test "the group is opt-in, and its readonly variant drops the write" do
    assert_not_includes Mcp::Context.new(tool_groups: nil).tools.map(&:tool_name), "get_operating_costs"
    assert_equal %w[get_operating_costs search_operating_cost_records action_operating_costs],
                 context.tools.map(&:tool_name)
    assert_equal %w[get_operating_costs search_operating_cost_records],
                 context("operating_costs_readonly").tools.map(&:tool_name)
    assert_not_includes context("self_session").tools.map(&:tool_name), "get_operating_costs"
  end

  test "action_operating_costs records a batch and stamps the calling session" do
    session = Session.create!(title: "collector", prompt: "x", git_root: "https://github.com/test/repo.git", branch: "main")

    receipt = call(Mcp::Tools::ActionOperatingCosts,
                   { action: "record", payload: operating_cost_payload, collector: "agent:daily" }, session_id: session.id)

    assert_equal 6, receipt.dig("counts", "accounts", "created")
    assert_equal [ session.id ], OperatingCostObservation.distinct.pluck(:recorded_by_session_id)
    assert_equal session.id, OperatingCostCollectionRun.find_by!(collector: "agent:daily").session_id
  end

  test "an invalid write is a tool error the caller can read" do
    error = assert_raises(Mcp::ToolError) do
      call(Mcp::Tools::ActionOperatingCosts, { action: "upsert_account", item: { key: "x", label: "X", vendor: "nope" } })
    end
    assert_match "Unknown vendor: nope", error.message
  end

  test "get_operating_costs answers every view and links the page" do
    seed_operating_costs!

    summary = call(Mcp::Tools::GetOperatingCosts, {})
    assert_equal "https://zimmer.example.com/costs", summary["page"]
    assert_includes summary["rows"].map { |r| r["key"] }, "gateway-infra"
    assert_equal [ "example-org" ], summary["paid_by_others"].map { |p| p["paid_by"] }

    by_vendor = call(Mcp::Tools::GetOperatingCosts, { view: "timeseries", group_by: "vendor" })
    assert by_vendor["series"].any?

    projections = call(Mcp::Tools::GetOperatingCosts, { view: "projections" })
    assert_equal 10, projections["monthly_strip"].size

    sources = call(Mcp::Tools::GetOperatingCosts, { view: "sources" })
    assert_includes sources["collection_runs"].map { |r| r["collector"] }, "agent:fixture"

    assert_raises(Mcp::ToolError) { call(Mcp::Tools::GetOperatingCosts, { vendor: "nope" }) }
  end

  test "search_operating_cost_records pages through one kind, narrowed by account" do
    seed_operating_costs!

    page = call(Mcp::Tools::SearchOperatingCostRecords, { kind: "observations", account: "examplecloud-gw-app", per_page: 2 })

    assert_equal 6, page["total"]
    assert_equal 2, page["records"].size
    assert page["has_more"]
    assert_raises(Mcp::ToolError) { call(Mcp::Tools::SearchOperatingCostRecords, { kind: "vendors", account: "examplecloud-gw-app" }) }
  end
end
