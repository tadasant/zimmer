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

  test "today is never counted, and nothing is derived for a deployment with no derived accounts" do
    LiveUsageEvent.record!(engine: "openai_realtime", operation: "voice_session", vendor: "openai", model: "gpt-realtime", seconds: 60,
                           occurred_at: @today.in_time_zone.change(hour: 1))
    assert_empty items(@voice)

    OperatingCostAccount.update_all(derived_source: nil)
    assert_empty OperatingCosts::DerivedCollector.new(today: @today).observations
  end
end
