# frozen_string_literal: true

require "test_helper"

class OperatingCosts::DerivedCollectorTest < ActiveSupport::TestCase
  setup do
    @today = Date.new(2026, 11, 17)
    vendor = OperatingCostVendor.create!(key: "voiceco", name: "VoiceCo", ingest_method: "derived")
    @voice = OperatingCostAccount.create!(key: "voice", label: "Voice", vendor: vendor, derived_source: "live_voice_metered")
    @pi = OperatingCostAccount.create!(key: "pi", label: "Pi", vendor: vendor, derived_source: "pi_token_spend")
  end

  def items(account) = OperatingCosts::DerivedCollector.new(today: @today).observations.select { |o| o["account"] == account.key }

  test "metered voice spend is summed per local day and subscription-billed voice is not money" do
    day = @today - 2
    LiveUsageEvent.record!(engine: "openai_realtime", operation: "voice_session", vendor: "openai", model: "gpt-realtime", seconds: 60,
                           occurred_at: day.in_time_zone.change(hour: 10))
    LiveUsageEvent.record!(engine: "gpt_live_claude", operation: "delegation", vendor: "anthropic", model: "claude-opus-5",
                           input_tokens: 1_000_000, occurred_at: day.in_time_zone.change(hour: 11), billing_basis: "subscription")
    metered = LiveUsageEvent.where(billing_basis: "metered").sum(:cost_usd)

    observed = items(@voice).sole

    assert_equal day.iso8601, observed["as_of_date"]
    assert_in_delta metered, observed["amount"], 0.0001
    assert_equal %w[derived estimated], observed.values_at("source", "confidence")
  end

  test "only the Pi runtime's token spend is counted, at list price" do
    usage = { model: "claude-opus-5", called_at: (@today - 1).in_time_zone.change(hour: 9), input_tokens: 0, output_tokens: 1_000_000 }
    SessionTokenUsage.create!(usage.merge(request_id: "pi-1", agent_runtime: "pi"))
    SessionTokenUsage.create!(usage.merge(request_id: "cc-1", agent_runtime: "claude_code"))

    observed = items(@pi).sole

    assert_in_delta TokenPricing.cost_for(model: "claude-opus-5", output_tokens: 1_000_000), observed["amount"], 0.0001
  end

  def pi_call(model, request_id, day: @today - 2, output_tokens: 1_000_000)
    SessionTokenUsage.create!(model: model, request_id: request_id, agent_runtime: "pi", input_tokens: 0, output_tokens: output_tokens,
                              called_at: day.in_time_zone.change(hour: 9))
  end

  test "Pi usage on a model with a published OpenRouter rate becomes a figure" do
    pi_call("openrouter/~google/gemini-pro-latest", "pi-gemini")

    observed = items(@pi).sole

    assert_in_delta 10.0, observed["amount"], 0.0001, "gemini-pro-latest output at $10/MTok"
    assert_no_match(/floor/, observed["evidence"])
  end

  test "a day whose only Pi usage is unpriced gets no figure, not a confident zero, and is reported as a gap" do
    pi_call("openrouter/example/unpriced-model", "pi-unknown")
    collector = OperatingCosts::DerivedCollector.new(today: @today)

    assert_empty items(@pi)
    gap = collector.gaps.fetch(@pi)
    assert_equal [ "openrouter/example/unpriced-model" ], gap[:unpriced_models]
    assert_equal @today - 2, gap[:unpriced_since]
    assert_nil gap[:last_due_on]
  end

  test "a day with priced and unpriced Pi usage records the priced part as a floor and names what it left out" do
    pi_call("openrouter/~anthropic/claude-opus-latest", "pi-opus")
    pi_call("openrouter/example/unpriced-model", "pi-unknown")

    observed = items(@pi).sole

    assert_in_delta TokenPricing.cost_for(model: "claude-opus-latest", output_tokens: 1_000_000), observed["amount"], 0.0001
    assert_match "A floor: excludes usage on openrouter/example/unpriced-model", observed["evidence"]
  end

  test "no Pi usage derives nothing and reports no gap" do
    collector = OperatingCosts::DerivedCollector.new(today: @today)

    assert_empty items(@pi)
    assert_equal({ last_due_on: nil, unpriced_models: [], unpriced_since: nil }, collector.gaps.fetch(@pi))
  end

  test "a derived observation in the window for a day it no longer derives is superseded" do
    pi_call("openrouter/example/unpriced-model", "pi-unknown")
    stale = OperatingCostObservation.create!(account: @pi, metric: "daily_cost", as_of_date: @today - 2, period_start: @today - 2,
                                             period_end: @today - 2, amount: 0, amount_usd: 0, currency: "USD", source: "derived",
                                             confidence: "estimated")
    billed = OperatingCostObservation.create!(account: @pi, metric: "daily_cost", as_of_date: @today - 2, period_start: @today - 2,
                                              period_end: @today - 2, amount: 3, amount_usd: 3, currency: "USD", source: "manual",
                                              confidence: "billed")

    assert_equal [ stale.id ], OperatingCosts::DerivedCollector.new(today: @today).superseded.pluck(:id)
    assert billed.persisted?
  end

  test "today is never counted, and nothing is derived for a deployment with no derived accounts" do
    LiveUsageEvent.record!(engine: "openai_realtime", operation: "voice_session", vendor: "openai", model: "gpt-realtime", seconds: 60,
                           occurred_at: @today.in_time_zone.change(hour: 1))
    assert_empty items(@voice)

    OperatingCostAccount.update_all(derived_source: nil)
    assert_empty OperatingCosts::DerivedCollector.new(today: @today).observations
  end
end
