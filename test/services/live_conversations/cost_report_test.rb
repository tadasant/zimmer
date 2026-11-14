# frozen_string_literal: true

require "test_helper"

class LiveConversations::CostReportTest < ActiveSupport::TestCase
  test "rolls the ledger up by engine, operation, day and conversation, with the speed signals beside the money" do
    gpt = create_live_conversation(mode: "voice", title: "GPT call")
    gpt.end!
    rt = create_live_conversation(mode: "voice", title: "Realtime call")
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1", seconds: 120, live_conversation: gpt)
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "delegation", vendor: "anthropic", model: "claude-sonnet-5-5",
                           input_tokens: 10_000, output_tokens: 1_000, latency_ms: 1_800, live_conversation: gpt)
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "turn_latency", vendor: "zimmer", first_audio_ms: 900, live_conversation: gpt)
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "turn_latency", vendor: "zimmer", first_audio_ms: 1_500, live_conversation: gpt)
    LiveUsageEvent.record!(engine: "openai_realtime", operation: "voice_tokens", vendor: "openai_realtime", model: "gpt-realtime-2.1-mini",
                           audio_output_tokens: 10_000, live_conversation: rt)
    LiveUsageEvent.record!(engine: "livekit_claude", operation: "engine_fallback", vendor: "zimmer", error: "not built", live_conversation: rt)
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1", seconds: 600,
                           live_conversation: gpt, occurred_at: 30.days.ago) # outside the window

    report = LiveConversations::CostReport.new(days: 7).as_api_json

    assert_in_delta 0.1 + 0.03 + 0.2, report[:totals][:cost_usd], 0.000001
    gpt_row = report[:by_engine].find { |row| row[:engine] == "gpt_live_claude" }
    assert_in_delta 0.13, gpt_row[:cost_usd], 0.000001
    assert_equal 1, gpt_row[:delegations]
    assert_equal 1_800, gpt_row[:avg_delegation_ms]
    assert_equal 1_200, gpt_row[:first_audio_ms_p50]
    assert_equal 2.0, gpt_row[:voice_session_minutes]
    livekit = report[:by_engine].find { |row| row[:engine] == "livekit_claude" }
    assert_equal 1, livekit[:fallbacks]
    assert_equal 0, livekit[:conversations], "a fallback is not a conversation the engine ran"
    assert_equal 1, gpt_row[:conversations]
    assert_in_delta 0.13, gpt_row[:cost_per_conversation_usd], 0.000001
    assert_equal [ [ "Realtime call", "openai_realtime" ], [ "GPT call", "gpt_live_claude" ] ], report[:by_conversation].map { |row| row.values_at(:title, :engine) }
    assert_equal %w[gpt_live_claude livekit_claude openai_realtime], report[:by_day].map { |row| row[:engine] }.sort
    assert_equal %w[gpt_live_claude livekit_claude], report[:caps].map { |cap| cap[:engine] }
    assert_equal LiveVoicePricing.version, report[:price_version]

    only = LiveConversations::CostReport.new(days: 7, engine: "openai_realtime").as_api_json
    assert_equal [ "openai_realtime" ], only[:by_engine].map { |row| row[:engine] }

    lines = LiveConversations::CostReport.new(days: 7).to_csv.split("\r\n")
    assert_equal LiveConversations::CostReport::CSV_COLUMNS.join(","), lines.first
    assert_equal 7, lines.size
    assert_includes lines.last, "not built"
  end

  test "refuses an engine that does not exist" do
    assert_raises(ArgumentError) { LiveConversations::CostReport.new(engine: "nope") }
  end
end
