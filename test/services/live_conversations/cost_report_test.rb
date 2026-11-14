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

    # Claude's $0.03 is on the subscription: at list price, not billed.
    assert_in_delta 0.1 + 0.2, report[:totals][:billed_usd], 0.000001
    assert_in_delta 0.1 + 0.03 + 0.2, report[:totals][:list_usd], 0.000001
    gpt_row = report[:by_mode].find { |row| row[:engine] == "gpt_live_claude" }
    assert_equal "gpt-live-1 + claude-sonnet-5-5", gpt_row[:mode]
    assert_in_delta 0.1, gpt_row[:billed_usd], 0.000001
    assert_in_delta 0.13, gpt_row[:list_usd], 0.000001
    assert_equal 1, gpt_row[:delegations]
    assert_equal 1_800, gpt_row[:avg_delegation_ms]
    assert_equal 1_200, gpt_row[:first_audio_ms_p50]
    livekit = report[:by_mode].find { |row| row[:engine] == "livekit_claude" }
    assert_equal 1, livekit[:fallbacks]
    assert_equal 0, livekit[:conversations], "a fallback is not a conversation the engine ran"
    assert_equal 1, gpt_row[:conversations]
    assert_in_delta 0.13, gpt_row[:list_per_conversation_usd], 0.000001
    assert_equal [ [ "Realtime call", "openai_realtime" ], [ "GPT call", "gpt_live_claude" ] ], report[:by_conversation].map { |row| row.values_at(:title, :engine) }
    assert_equal %w[gpt_live_claude livekit_claude openai_realtime], report[:by_day].map { |row| row[:engine] }.sort
    assert_equal %w[gpt_live_claude livekit_claude], report[:caps].map { |cap| cap[:engine] }
    assert_equal LiveVoicePricing.version, report[:price_version]

    only = LiveConversations::CostReport.new(days: 7, engine: "openai_realtime").as_api_json
    assert_equal [ "openai_realtime" ], only[:by_mode].map { |row| row[:engine] }

    lines = LiveConversations::CostReport.new(days: 7).to_csv.split("\r\n")
    assert_equal LiveConversations::CostReport::CSV_COLUMNS.join(","), lines.first
    assert_equal 7, lines.size
    assert_includes lines.last, "not built"

    LiveUsageEvent.record!(engine: "openai_realtime", operation: "turn_latency", vendor: "zimmer", error: "=HYPERLINK(\"x\")")
    assert_includes LiveConversations::CostReport.new(days: 7).to_csv, %("'=HYPERLINK(""x"")")
  end

  test "a tab closing mid-call sends its minutes so far, and the call still counts once" do
    conversation = create_live_conversation(mode: "voice", voice_engine: "openai_realtime", voice_mode: "gpt-realtime-2.1-mini")
    LiveConversations::UsageReport.call(conversation, [
      { "engine" => "openai_realtime", "operation" => "call", "key" => "p.1", "seconds" => 60, "details" => { "partial" => true } },
      { "engine" => "openai_realtime", "operation" => "call", "key" => "p.2", "seconds" => 30 }
    ])

    row = LiveConversations::CostReport.new(days: 1).by_mode.sole
    assert_equal 1, row[:calls]
    assert_equal 1.5, row[:call_minutes]
  end

  test "modes compare like for like: each Realtime model and effort is its own mode, with cost per call-minute" do
    conversation = create_live_conversation(mode: "voice")
    LiveSetting.editable.update!(voice_reasoning_effort: "high")
    LiveConversations::UsageReport.call(conversation, [
      { "engine" => "openai_realtime", "operation" => "voice_tokens", "key" => "a.1", "audio_output_tokens" => 100_000 },
      { "engine" => "openai_realtime", "operation" => "call", "key" => "a.2", "seconds" => 120 }
    ], model: "gpt-realtime-2.1")
    LiveSetting.editable.update!(voice_reasoning_effort: nil)
    LiveConversations::UsageReport.call(conversation, [
      { "engine" => "openai_realtime", "operation" => "voice_tokens", "key" => "b.1", "audio_output_tokens" => 100_000 }
    ], model: "gpt-realtime-2.1-mini")

    modes = LiveConversations::CostReport.new(days: 1).by_mode.index_by { |row| row[:mode] }

    full = modes.fetch("gpt-realtime-2.1 · effort high")
    assert_in_delta 6.4, full[:billed_usd], 0.000001
    assert_equal 2.0, full[:call_minutes]
    assert_in_delta 3.2, full[:billed_per_minute_usd], 0.000001
    assert_in_delta 2.0, modes.fetch("gpt-realtime-2.1-mini")[:billed_usd], 0.000001
    assert_nil modes.fetch("gpt-realtime-2.1-mini")[:billed_per_minute_usd], "no call timed, no per-minute figure"
  end

  test "Claude runs on Zimmer's subscription: recorded at list price, billed at nothing, and still counted by the caps" do
    conversation = create_live_conversation(mode: "voice")
    LiveSetting.editable.update!(voice_engine_conversation_cap_usd: 1.0)
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "delegation", vendor: "anthropic", model: "claude-sonnet-5-5",
                           input_tokens: 1_000_000, live_conversation: conversation)
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1",
                           seconds: 60, live_conversation: conversation)

    claude = LiveUsageEvent.find_by!(operation: "delegation")
    assert_equal "subscription", claude.billing_basis
    assert_equal "metered", LiveUsageEvent.find_by!(operation: "voice_session").billing_basis
    totals = LiveConversations::CostReport.new(days: 1).totals
    assert_in_delta 2.05, totals[:list_usd], 0.000001
    assert_in_delta 0.05, totals[:billed_usd], 0.000001
    assert LiveConversations::SpendGuard.check(engine: "gpt_live_claude", conversation: conversation).blocked?,
           "the subscription's quota is shared and finite, so list price still counts toward the cap"
  end

  test "refuses an engine that does not exist" do
    assert_raises(ArgumentError) { LiveConversations::CostReport.new(engine: "nope") }
  end
end
