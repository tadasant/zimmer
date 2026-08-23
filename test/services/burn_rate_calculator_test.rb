# frozen_string_literal: true

require "test_helper"

# The rate the scheduler multiplies by "how long until I look again". It has to
# come out of the same ledger, at the same prices, as the Costs tab — a rate
# priced differently from the page would make two numbers nobody could reconcile.
class BurnRateCalculatorTest < ActiveSupport::TestCase
  setup do
    SessionTokenUsage.delete_all
    HarnessModelBurnRate.delete_all
    @session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "work",
                               genesis: SessionGenesis::WEB_UI)
  end

  # One session's worth of calls on one combination, spanning `minutes`.
  def spend(session:, harness: "zimmer", model: "claude-opus-5", minutes: 10, at: 1.hour.ago, output_tokens: 1_000_000)
    [ at, at + minutes.minutes ].each_with_index do |called_at, i|
      SessionTokenUsage.create!(
        request_id: "req_#{SecureRandom.hex(6)}", model: model, agent_root: harness,
        session_id: session.id, called_at: called_at,
        input_tokens: 0, output_tokens: i.zero? ? output_tokens : 0,
        cache_read_tokens: 0, cache_creation_tokens: 0
      )
    end
  end

  def other_session(name)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: name, genesis: SessionGenesis::WEB_UI)
  end

  test "the rate is spend over elapsed session minutes, at the Costs tab's prices" do
    # 1M Opus output tokens is $25 at TokenPricing's rate, over a 10-minute span.
    spend(session: @session, minutes: 10, output_tokens: 1_000_000)

    sample = BurnRateCalculator.compute_samples.sole

    assert_equal "zimmer", sample.harness
    assert_equal "claude-opus-5", sample.model
    assert_in_delta 25.0, sample.cost_usd, 0.0001
    assert_in_delta 10.0, sample.minutes, 0.0001
    assert_in_delta 2.5, sample.usd_per_minute, 0.0001
    assert_equal 1, sample.sessions
  end

  # Costs and minutes are summed across the sample before dividing. Averaging
  # per-session rates instead would give a two-call, one-second session the same
  # weight as a two-hour one.
  test "the rate pools cost and minutes across sessions rather than averaging rates" do
    spend(session: @session, minutes: 10, output_tokens: 1_000_000)          # $25 / 10 min
    spend(session: other_session("b"), minutes: 40, output_tokens: 1_000_000) # $25 / 40 min

    sample = BurnRateCalculator.compute_samples.sole

    assert_equal 2, sample.sessions
    assert_in_delta 50.0, sample.cost_usd, 0.0001
    assert_in_delta 50.0, sample.minutes, 0.0001
    assert_in_delta 1.0, sample.usd_per_minute, 0.0001,
      "the mean of 2.5 and 0.625 would be 1.5625 — pooling is what makes the long session count"
  end

  # The named constant, not a magic number: only the most recent
  # SAMPLE_SESSIONS sessions of a combination inform its rate.
  test "only the newest SAMPLE_SESSIONS sessions of a combination are sampled" do
    (HarnessModelBurnRate::SAMPLE_SESSIONS + 5).times do |i|
      spend(session: other_session("s#{i}"), minutes: 10, at: (i + 1).hours.ago, output_tokens: 1_000_000)
    end

    sample = BurnRateCalculator.compute_samples.sole

    assert_equal HarnessModelBurnRate::SAMPLE_SESSIONS, sample.sessions
    assert_in_delta HarnessModelBurnRate::SAMPLE_SESSIONS * 10.0, sample.minutes, 0.0001
  end

  test "the newest sessions are the ones kept, not an arbitrary 25" do
    spend(session: other_session("old"), minutes: 10, at: 20.days.ago, output_tokens: 1_000_000)
    HarnessModelBurnRate::SAMPLE_SESSIONS.times do |i|
      spend(session: other_session("new#{i}"), minutes: 10, at: (i + 1).hours.ago, output_tokens: 2_000_000)
    end

    sample = BurnRateCalculator.compute_samples.sole

    assert_in_delta 5.0, sample.usd_per_minute, 0.0001,
      "the sample is the recent, more expensive sessions — the old one is crowded out"
    assert sample.oldest_at > 2.days.ago, "nothing older than the newest 25 is in the window"
  end

  # A session with one API call spans zero seconds. Dividing by that would hand
  # the scheduler an infinite burn rate, which would hold every spot session for
  # ever.
  test "a single-call session is floored rather than dividing by zero" do
    SessionTokenUsage.create!(
      request_id: "req_solo", model: "claude-opus-5", agent_root: "zimmer",
      session_id: @session.id, called_at: 1.hour.ago,
      input_tokens: 0, output_tokens: 1_000_000, cache_read_tokens: 0, cache_creation_tokens: 0
    )

    sample = BurnRateCalculator.compute_samples.sole

    assert_in_delta HarnessModelBurnRate::MIN_SESSION_MINUTES, sample.minutes, 0.0001
    assert sample.usd_per_minute.finite?, "an infinite rate would hold every spot session for ever"
    assert_in_delta 25.0, sample.usd_per_minute, 0.0001
  end

  # The edge case the whole fallback path exists for: a combination nobody has
  # run has no rate, and the caller has to be able to tell that apart from zero.
  test "an empty ledger produces no rates at all" do
    assert_empty BurnRateCalculator.compute_samples
    assert_equal 0, BurnRateCalculator.recompute_all
    assert_nil HarnessModelBurnRate.fleet_default_usd_per_minute
  end

  test "a harness with no sample falls back to the fleet default, not to free" do
    spend(session: @session, minutes: 10, output_tokens: 1_000_000)
    BurnRateCalculator.recompute_all

    assert_nil HarnessModelBurnRate.table[[ "brand-new-root", "claude-opus-5" ]]
    assert_in_delta 2.5, HarnessModelBurnRate.fleet_default_usd_per_minute, 0.0001
  end

  # The fleet default is cost-weighted, so it looks like the work the fleet
  # actually does rather than letting a dozen rarely-used combinations outvote
  # the root that spends the money.
  test "the fleet default is cost-weighted, not a plain mean of rates" do
    spend(session: @session, harness: "big", minutes: 100, at: 3.hours.ago, output_tokens: 4_000_000) # $100 / 100 min
    spend(session: other_session("tiny"), harness: "tiny", minutes: 1, output_tokens: 40_000)        # $1 / 1 min
    BurnRateCalculator.recompute_all

    assert_in_delta 1.0, HarnessModelBurnRate.table[[ "big", "claude-opus-5" ]], 0.0001
    assert_in_delta 1.0, HarnessModelBurnRate.table[[ "tiny", "claude-opus-5" ]], 0.0001
    assert_in_delta 1.0, HarnessModelBurnRate.fleet_default_usd_per_minute, 0.0001
  end

  test "rates are split per harness and per model, not pooled together" do
    spend(session: @session, harness: "zimmer", model: "claude-opus-5", minutes: 10, output_tokens: 1_000_000)
    spend(session: other_session("h"), harness: "zimmer", model: "claude-haiku-4-5", minutes: 10, output_tokens: 1_000_000)
    spend(session: other_session("r"), harness: "zimmer-router", model: "claude-opus-5", minutes: 10, output_tokens: 1_000_000)

    BurnRateCalculator.recompute_all
    table = HarnessModelBurnRate.table

    assert_equal 3, table.size
    assert_in_delta 2.5, table[[ "zimmer", "claude-opus-5" ]], 0.0001
    assert_in_delta 0.5, table[[ "zimmer", "claude-haiku-4-5" ]], 0.0001,
      "Haiku output is a fifth of Opus, and the rate has to say so"
    assert_in_delta 2.5, table[[ "zimmer-router", "claude-opus-5" ]], 0.0001
  end

  # Spend the transcript-to-session join could not attribute has no session to be
  # a rate PER, so it cannot inform one.
  test "unattributed spend is left out" do
    SessionTokenUsage.create!(
      request_id: "req_orphan", model: "claude-opus-5", agent_root: "zimmer",
      session_id: nil, called_at: 1.hour.ago,
      input_tokens: 0, output_tokens: 9_000_000, cache_read_tokens: 0, cache_creation_tokens: 0
    )

    assert_empty BurnRateCalculator.compute_samples
  end

  test "spend outside the lookback is not sampled" do
    spend(session: @session, minutes: 10, at: (HarnessModelBurnRate::SAMPLE_LOOKBACK + 1.day).ago)

    assert_empty BurnRateCalculator.compute_samples
  end

  # A combination that falls out of the lookback must not go on informing the
  # scheduler from its last recorded value.
  test "recompute drops a combination that no longer has recent spend" do
    spend(session: @session, minutes: 10, output_tokens: 1_000_000)
    assert_equal 1, BurnRateCalculator.recompute_all
    assert_equal 1, HarnessModelBurnRate.count

    SessionTokenUsage.delete_all
    assert_equal 0, BurnRateCalculator.recompute_all
    assert_equal 0, HarnessModelBurnRate.count
  end

  test "recompute is idempotent — a second run rewrites the same row" do
    spend(session: @session, minutes: 10, output_tokens: 1_000_000)

    BurnRateCalculator.recompute_all
    BurnRateCalculator.recompute_all

    assert_equal 1, HarnessModelBurnRate.count
    assert_in_delta 2.5, HarnessModelBurnRate.sole.usd_per_minute, 0.0001
  end

  # A rate the cron has stopped refreshing is not a rate the scheduler may go on
  # deciding with.
  test "a stale rate is excluded from the table and the default" do
    spend(session: @session, minutes: 10, output_tokens: 1_000_000)
    BurnRateCalculator.recompute_all

    HarnessModelBurnRate.update_all(computed_at: (HarnessModelBurnRate::FRESHNESS_HORIZON + 1.hour).ago)

    assert_empty HarnessModelBurnRate.table
    assert_nil HarnessModelBurnRate.fleet_default_usd_per_minute
    refute HarnessModelBurnRate.sole.fresh?
  end

  test "the job persists what the calculator computes" do
    spend(session: @session, minutes: 10, output_tokens: 1_000_000)

    assert_equal 1, BurnRateRecomputeJob.new.perform

    rate = HarnessModelBurnRate.sole
    assert_in_delta 2.5, rate.usd_per_minute, 0.0001
    assert_in_delta 150.0, rate.usd_per_hour, 0.0001
    assert rate.fresh?
  end
end
