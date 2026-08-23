# frozen_string_literal: true

require "test_helper"

class TokenPricingTest < ActiveSupport::TestCase
  # These are the published list rates. They are asserted literally because a
  # silent drift here mis-states every figure on the Costs page, and because the
  # first version of this analysis was wrong by 3x from exactly this kind of
  # remembered-instead-of-checked rate.
  test "opus rates match list price" do
    rate = TokenPricing.rate_for("claude-opus-5")

    assert_equal 5.0, rate.input
    assert_equal 25.0, rate.output
    assert_equal 0.5, rate.cache_read
    assert_equal 6.25, rate.cache_write_5m
    assert_equal 10.0, rate.cache_write_1h
  end

  test "sonnet and haiku rates match list price" do
    sonnet = TokenPricing.rate_for("claude-sonnet-5")
    assert_equal [ 3.0, 15.0, 0.3, 3.75, 6.0 ],
      [ sonnet.input, sonnet.output, sonnet.cache_read, sonnet.cache_write_5m, sonnet.cache_write_1h ]

    haiku = TokenPricing.rate_for("claude-haiku-4-5")
    assert_equal [ 1.0, 5.0, 0.1, 1.25, 2.0 ],
      [ haiku.input, haiku.output, haiku.cache_read, haiku.cache_write_5m, haiku.cache_write_1h ]
  end

  test "resolves dated snapshots and unknown families" do
    assert_equal "haiku", TokenPricing.family_for("claude-haiku-4-5-20251001")
    assert_equal "opus", TokenPricing.family_for("claude-opus-4-8")
    assert_nil TokenPricing.family_for("gpt-5.6-sol")
    assert_nil TokenPricing.family_for(nil)
  end

  test "an unknown model prices at zero rather than guessing a rate" do
    # A wrong rate is worse than a visibly missing one: it lands inside a total
    # that reads as authoritative. CostAnalytics#unpriced_models surfaces these.
    assert_not TokenPricing.priced?("claude-unreleased-9")
    assert_equal 0.0, TokenPricing.cost_for(model: "claude-unreleased-9", input_tokens: 1_000_000)
  end

  test "prices each token bucket at its own rate" do
    cost = TokenPricing.cost_for(
      model: "claude-opus-5",
      input_tokens: 1_000_000,
      output_tokens: 1_000_000,
      cache_read_tokens: 1_000_000,
      cache_creation_tokens: 2_000_000,
      cache_creation_5m_tokens: 1_000_000,
      cache_creation_1h_tokens: 1_000_000
    )

    # 5 + 25 + 0.50 + 6.25 + 10
    assert_in_delta 46.75, cost, 0.001
  end

  test "charges an unsplit cache write at the 1 hour rate" do
    # Older transcript lines predate the `cache_creation` sub-object. Charging
    # the conservative rate is right for this deployment, where 95% of observed
    # cache writes are on the 1-hour TTL.
    cost = TokenPricing.cost_for(
      model: "claude-opus-5", cache_creation_tokens: 1_000_000,
      cache_creation_5m_tokens: 0, cache_creation_1h_tokens: 0
    )

    assert_in_delta 10.0, cost, 0.001
  end

  test "bills web search per request, not per token" do
    assert_in_delta 10.0,
      TokenPricing.cost_for(model: "claude-opus-5", web_search_requests: 1_000), 0.001
  end

  test "refuses to build pricing SQL for a table that is not ours" do
    # The table name is interpolated into SQL. It is always a model's own
    # `table_name` today; the allowlist is what keeps that true for callers that
    # do not exist yet.
    assert_raises(ArgumentError) { TokenPricing.cost_sql("users; DROP TABLE sessions") }
    assert TokenPricing.cost_sql("session_token_usages").present?
  end

  # --- denominating in one model ------------------------------------------------

  test "refuses to denominate in a family it has no rate for" do
    assert_raises(ArgumentError) { TokenPricing.cost_sql("session_token_usages", as_family: "gpt") }
    assert TokenPricing.cost_sql("session_token_usages", as_family: "opus").present?
  end

  # Denominating replaces the RATE, never the MATCH. A quota figure expressed
  # "in Opus dollars" has to re-price a Haiku row at Opus money — and still leave
  # a model nothing knows how to price contributing zero, rather than quietly
  # inheriting Opus's rate and inflating the estimate.
  test "denominating re-prices every known model at one family's rate" do
    usage = SessionTokenUsage.create!(
      request_id: "req_#{SecureRandom.hex(6)}", model: "claude-haiku-4-5",
      agent_root: "zimmer", called_at: 1.hour.ago,
      input_tokens: 0, output_tokens: 1_000_000, cache_read_tokens: 0, cache_creation_tokens: 0
    )
    scope = SessionTokenUsage.where(id: usage.id)

    billed = scope.pick(Arel.sql("SUM(#{TokenPricing.cost_sql('session_token_usages')})")).to_f
    in_opus = scope.pick(Arel.sql("SUM(#{TokenPricing.cost_sql('session_token_usages', as_family: 'opus')})")).to_f

    assert_in_delta 5.0, billed, 0.0001, "1M Haiku output tokens bill at $5/M"
    assert_in_delta 25.0, in_opus, 0.0001, "…and re-price at Opus's $25/M"
  end

  test "denominating leaves an unpriced model at zero" do
    usage = SessionTokenUsage.create!(
      request_id: "req_#{SecureRandom.hex(6)}", model: "some-future-model",
      agent_root: "zimmer", called_at: 1.hour.ago,
      input_tokens: 0, output_tokens: 1_000_000, cache_read_tokens: 0, cache_creation_tokens: 0
    )

    in_opus = SessionTokenUsage.where(id: usage.id)
      .pick(Arel.sql("SUM(#{TokenPricing.cost_sql('session_token_usages', as_family: 'opus')})")).to_f

    assert_in_delta 0.0, in_opus, 0.0001,
      "a model with no rate must stay visibly unpriced rather than inherit Opus money"
  end

  test "the SQL expression agrees with the Ruby one" do
    # These two must never diverge: the page totals come from SQL and the
    # per-row figures from Ruby, and a mismatch would show as a page whose parts
    # do not add up to its own total.
    [
      { model: "claude-opus-5", input_tokens: 1_234, output_tokens: 5_678,
        cache_read_tokens: 900_000, cache_creation_tokens: 40_000,
        cache_creation_1h_tokens: 40_000 },
      { model: "claude-sonnet-5", input_tokens: 10, output_tokens: 20,
        cache_read_tokens: 30, cache_creation_tokens: 40,
        cache_creation_5m_tokens: 40 },
      { model: "claude-haiku-4-5", input_tokens: 7, output_tokens: 0,
        cache_read_tokens: 0, cache_creation_tokens: 99, web_search_requests: 3 }
    ].each_with_index do |attrs, i|
      SessionTokenUsage.create!(attrs.reverse_merge(
        request_id: "req_sql_#{i}", called_at: 1.hour.ago,
        cache_creation_5m_tokens: 0, cache_creation_1h_tokens: 0
      ))
    end

    ruby_total = SessionTokenUsage.sum(&:cost_usd)
    sql_total = SessionTokenUsage.totals[:cost_usd]

    assert_in_delta ruby_total, sql_total, 0.0001
  end
end
