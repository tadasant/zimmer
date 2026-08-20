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

  test "says plainly when nothing has been ingested, and how to load history" do
    output = @tool.call({})

    assert_match "No token usage recorded", output
    assert_match "token_usage:backfill", output
  end

  test "reports the fleet breakdown" do
    usage
    usage(agent_root: "issue-work-gate", model: "claude-sonnet-5")

    output = @tool.call({ "days" => 7 })

    assert_match "Token spend — last 7 days", output
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

    assert_match "last 365 days", output
  end
end
