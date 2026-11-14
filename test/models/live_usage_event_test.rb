# frozen_string_literal: true

require "test_helper"

class LiveUsageEventTest < ActiveSupport::TestCase
  test "prices a row from the price table as it is written, and stamps the table's version" do
    event = LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "delegation", vendor: "anthropic", model: "claude-sonnet-5-5",
                                   input_tokens: 1_000_000, output_tokens: 100_000, cache_read_tokens: 1_000_000, cache_write_tokens: 1_000_000)

    # $2 in + $1 out + $0.10 cache read + $2.50 cache write, per the 2026-11-14 table.
    assert_in_delta 5.60, event.cost_usd.to_f, 0.000001
    assert event.priced
    assert_equal LiveVoicePricing.version, event.price_version
  end

  test "GPT-Live is billed by the second" do
    event = LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1", seconds: 90)

    assert_in_delta 0.075, event.cost_usd.to_f, 0.000001
  end

  test "a Realtime response prices text, audio and cached tokens at their own rates" do
    event = LiveUsageEvent.record!(engine: "openai_realtime", operation: "voice_tokens", vendor: "openai_realtime", model: "gpt-realtime-2.1-mini",
                                   input_tokens: 1_000_000, audio_input_tokens: 1_000_000, output_tokens: 1_000_000,
                                   audio_output_tokens: 1_000_000, cache_read_tokens: 1_000_000)

    # text in 0.60 + audio in 10 + text out 2.40 + audio out 20 + cached 0.30
    assert_in_delta 33.30, event.cost_usd.to_f, 0.000001
  end

  test "a model the table does not list is recorded unpriced at zero rather than guessed" do
    event = LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "delegation", vendor: "anthropic", model: "claude-new-9", input_tokens: 500)

    assert_equal 0, event.cost_usd
    assert_not event.priced
  end

  test "a cost the writer supplies is ignored: the table prices every row" do
    event = LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1",
                                   seconds: 60, cost_usd: 999)

    assert_in_delta 0.05, event.cost_usd.to_f, 0.000001
  end

  test "a repeated idempotency key counts once" do
    first = LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1", seconds: 60, idempotency_key: "k1")
    again = LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "voice_session", vendor: "openai_live", model: "gpt-live-1", seconds: 60, idempotency_key: "k1")

    assert_equal first, again
    assert_equal 1, LiveUsageEvent.count
  end

  test "refuses an unknown engine or operation" do
    assert_raises(ActiveRecord::RecordInvalid) { LiveUsageEvent.record!(engine: "nope", operation: "delegation") }
    assert_raises(ActiveRecord::RecordInvalid) { LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "nope") }
  end
end
