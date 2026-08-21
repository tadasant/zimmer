# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::GetCostsTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetCosts.new(context: Mcp::Context.new(tool_groups: "health"))
    @session = sessions(:running)
  end

  def usage(**overrides)
    SessionTokenUsage.create!({
      request_id: "req_#{SecureRandom.hex(6)}",
      model: "claude-opus-5",
      agent_root: "zimmer-router",
      session_id: @session.id,
      called_at: 2.hours.ago,
      input_tokens: 100,
      output_tokens: 1_000,
      cache_read_tokens: 500_000,
      cache_creation_tokens: 200_000,
      cache_creation_1h_tokens: 200_000
    }.merge(overrides))
  end

  test "says plainly when nothing has been ingested, and that the sweep runs itself" do
    output = @tool.call({})

    assert_match "No token usage recorded", output
    assert_match "TokenUsageBackfillJob", output
    assert_match "never_run", output, "an agent should be able to tell a quiet fleet from an unswept ledger"
  end

  test "reports the fleet breakdown" do
    usage
    usage(agent_root: "issue-work-gate", model: "claude-sonnet-5")

    output = @tool.call({ "days" => 7 })

    assert_match "Token spend — 7 days", output
    assert_match "Where the money goes", output
    assert_match "zimmer-router", output
    assert_match "issue-work-gate", output
    assert_match "claude-sonnet-5", output
    # Cache writes bill at 2x base input, so they should lead a bill like this
    # one rather than the output tokens the work actually produced.
    assert_match "cache write (1h)", output
  end

  test "carries the daily series the page and REST API both show" do
    usage(called_at: 1.day.ago)
    usage(called_at: 3.days.ago)

    output = @tool.call({ "days" => 7 })

    assert_match "### Daily", output
    assert_match 1.day.ago.to_date.to_s, output
    assert_match 3.days.ago.to_date.to_s, output
  end

  test "scopes to one agent root" do
    usage
    usage(agent_root: "issue-work-gate")

    output = @tool.call({ "agent_root" => "zimmer-router" })

    assert_match "`zimmer-router`", output
    assert_match "of fleet", output
    assert_no_match(/issue-work-gate/, output)
  end

  test "scopes to one session and splits main from subagent" do
    usage
    usage(subagent: true, output_tokens: 10)

    output = @tool.call({ "session_id" => @session.id })

    assert_match "Session ##{@session.id}", output
    assert_match "Main thread:", output
    assert_match "subagents:", output
  end

  test "names an unknown agent root instead of rendering an empty table" do
    usage

    assert_match "No spend recorded for agent root `nope`", @tool.call({ "agent_root" => "nope" })
  end

  test "flags models it has no price for" do
    usage(model: "claude-unreleased-9")

    output = @tool.call({})

    assert_match "Unpriced models", output
    assert_match "claude-unreleased-9", output
  end

  test "clamps an out-of-range window rather than scanning everything" do
    usage(called_at: 2.hours.ago)

    output = @tool.call({ "days" => 10_000 })

    assert_match "1 year", output
  end

  test "accepts an explicit calendar window, matching what the Costs page offers" do
    usage(called_at: Time.zone.parse("2026-03-10 12:00"), agent_root: "zimmer-router")

    inside = @tool.call({ "from" => "2026-03-09", "to" => "2026-03-11" })
    assert_match "Mar 9 – Mar 11, 2026", inside
    assert_match "zimmer-router", inside

    outside = @tool.call({ "from" => "2026-03-01", "to" => "2026-03-05" })
    assert_match "No token usage recorded", outside
  end

  test "declares from and to in its schema so an agent can drive the calendar window" do
    properties = Mcp::Tools::GetCosts.input_schema.to_h.deep_symbolize_keys[:properties]

    assert properties.key?(:from), "schema must expose the calendar window start"
    assert properties.key?(:to), "schema must expose the calendar window end"
  end

  test "reports the context-feature split as an estimate, with its residual" do
    record = usage(called_at: 2.hours.ago, agent_root: "zimmer-router")
    feature_row(record, "goal", cache_read_tokens: 100_000)

    output = @tool.call({})

    assert_match "Context features (estimated)", output
    assert_match "Session goal", output
    assert_match "_unattributed_", output
    assert_match "not measured", output
  end

  test "the agent-root report carries the feature drilldown" do
    record = usage(called_at: 2.hours.ago, agent_root: "zimmer-router")
    feature_row(record, "mcp_result", cache_read_tokens: 50_000)

    output = @tool.call({ "agent_root" => "zimmer-router" })

    assert_match "Context features (estimated)", output
    assert_match "MCP responses", output
  end

  private

  def feature_row(record, feature, **volumes)
    TokenUsageFeature.create!(
      request_id: record.request_id, feature: feature, session_id: record.session_id,
      agent_root: record.agent_root, model: record.model, subagent: record.subagent,
      called_at: record.called_at, **volumes
    )
  end

  test "warns that the figures are partial until the historical sweep finishes" do
    usage
    TokenUsageBackfill.create!(transcript_root: "/tmp/projects", started_at: 1.minute.ago,
                               directories_total: 100, directories_done: 40)

    output = @tool.call({})

    assert_match "Partial history", output
    assert_match "40% swept", output
  end

  test "a re-scan of already-swept history is not reported as partial" do
    usage
    TokenUsageBackfill.create!(transcript_root: "/tmp/projects", started_at: 3.hours.ago, finished_at: 2.hours.ago)
    TokenUsageBackfill.create!(transcript_root: "/tmp/projects", trigger: "manual",
                               started_at: 1.minute.ago, directories_total: 100, directories_done: 40)

    output = @tool.call({})

    assert_match "A re-scan of the corpus is running", output
    assert_no_match(/Partial history/, output)
  end

  test "states the covered window once the sweep has finished" do
    usage
    TokenUsageBackfill.create!(transcript_root: "/tmp/projects", started_at: 2.hours.ago, finished_at: 1.hour.ago)

    output = @tool.call({})

    assert_match "Ledger covers", output
    assert_no_match(/Partial history/, output)
  end
end
