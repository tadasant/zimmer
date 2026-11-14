# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::GetLiveCostsTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetLiveCosts.new(context: Mcp::Context.new(tool_groups: "live_conversations", base_url: "https://zimmer.example.com"))
  end

  test "is a read on the live_conversations surface, and survives _readonly" do
    assert_includes Mcp::Context.new(tool_groups: "live_conversations_readonly").tools.map(&:tool_name), "get_live_costs"
  end

  test "answers the cost report as JSON, narrowed by engine and window" do
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1", seconds: 60)
    LiveUsageEvent.record!(engine: "openai_realtime", operation: "voice_tokens", vendor: "openai_realtime", model: "gpt-realtime-2.1-mini", audio_output_tokens: 1_000)

    all = JSON.parse(@tool.call({ "days" => 2 }))
    assert_equal %w[gpt_live_claude openai_realtime], all["by_engine"].map { |row| row["engine"] }.sort
    assert_equal "https://zimmer.example.com/live/costs", all["page"]

    only = JSON.parse(@tool.call({ "engine" => "openai_realtime" }))
    assert_equal [ "openai_realtime" ], only["by_engine"].map { |row| row["engine"] }
  end

  test "an unknown engine is a tool error" do
    assert_raises(Mcp::ToolError) { @tool.call({ "engine" => "nope" }) }
  end
end
