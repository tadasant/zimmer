# frozen_string_literal: true

require "test_helper"

class LiveConversations::UsageReportTest < ActiveSupport::TestCase
  setup do
    @conversation = create_live_conversation(mode: "voice", model: "gpt-realtime-2.1-mini")
  end

  test "a Realtime call's tokens are priced on the conversation's own model, not one the client names" do
    result = LiveConversations::UsageReport.call(@conversation, [
      { "engine" => "openai_realtime", "operation" => "voice_tokens", "key" => "c1.1", "model" => "free-model",
        "audio_input_tokens" => 1_000_000, "cost_usd" => 0 },
      { "engine" => "openai_realtime", "operation" => "transcription", "key" => "c1.2", "input_tokens" => 1_000_000 },
      { "engine" => "openai_realtime", "operation" => "turn_latency", "key" => "c1.3", "first_audio_ms" => 820 }
    ])

    assert_equal 3, result.recorded
    tokens = LiveUsageEvent.find_by!(operation: "voice_tokens")
    assert_equal "gpt-realtime-2.1-mini", tokens.model
    assert_in_delta 10.0, tokens.cost_usd.to_f, 0.000001
    assert_equal "gpt-4o-mini-transcribe", LiveUsageEvent.find_by!(operation: "transcription").model
    assert_equal 820, LiveUsageEvent.find_by!(operation: "turn_latency").first_audio_ms
    assert_in_delta 11.25, result.cost_usd, 0.000001
  end

  test "a batch sent twice counts once" do
    @conversation.update_columns(voice_engine: "gpt_live_claude")
    event = { "engine" => "gpt_live_claude", "operation" => "voice_session", "key" => "abc.1", "seconds" => 120 }
    assert_equal 1, LiveConversations::UsageReport.call(@conversation, [ event ]).recorded
    assert_equal 0, LiveConversations::UsageReport.call(@conversation, [ event ]).recorded

    assert_equal 1, LiveUsageEvent.count
    assert_in_delta 0.10, LiveUsageEvent.sole.cost_usd.to_f, 0.000001
  end

  test "refuses what a client may not report, and clamps what it may" do
    assert_raises(LiveConversations::UsageReport::Invalid) do
      LiveConversations::UsageReport.call(@conversation, [ { "engine" => "gpt_live_claude", "operation" => "delegation", "key" => "k" } ])
    end
    assert_raises(LiveConversations::UsageReport::Invalid) do
      LiveConversations::UsageReport.call(@conversation, [ { "engine" => "openai_realtime", "operation" => "voice_session", "key" => "k" } ])
    end
    assert_raises(LiveConversations::UsageReport::Invalid) do
      LiveConversations::UsageReport.call(@conversation, [ { "engine" => "openai_realtime", "operation" => "voice_tokens", "key" => "bad key!" } ])
    end

    assert_raises(LiveConversations::UsageReport::Invalid) { LiveConversations::UsageReport.call(@conversation, [ "x" ]) }
    # GPT-Live seconds only for a call that ran on GPT-Live.
    assert_raises(LiveConversations::UsageReport::Invalid) do
      LiveConversations::UsageReport.call(@conversation, [ { "engine" => "gpt_live_claude", "operation" => "voice_session", "key" => "k", "seconds" => 60 } ])
    end

    @conversation.update_columns(voice_engine: "gpt_live_claude")
    LiveConversations::UsageReport.call(@conversation, [ { "engine" => "gpt_live_claude", "operation" => "voice_session", "key" => "k", "seconds" => -5 } ])
    assert_equal 0, LiveUsageEvent.sole.seconds
  end

  test "Realtime tokens are priced on the model the call was minted with, when the settings offer it" do
    @conversation.update_columns(model: "gpt-6-luna") # typed since
    event = { "engine" => "openai_realtime", "operation" => "voice_tokens", "key" => "m.1", "audio_output_tokens" => 1_000_000 }

    LiveConversations::UsageReport.call(@conversation, [ event ], model: "gpt-realtime-2.1")
    assert_equal "gpt-realtime-2.1", LiveUsageEvent.last.model
    assert_in_delta 64.0, LiveUsageEvent.last.cost_usd.to_f, 0.000001

    LiveConversations::UsageReport.call(@conversation, [ event.merge("key" => "m.2") ], model: "free-model")
    assert_equal "gpt-6-luna", LiveUsageEvent.last.model, "a model the settings do not offer is ignored"
  end
end
