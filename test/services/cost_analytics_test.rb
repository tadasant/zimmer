# frozen_string_literal: true

require "test_helper"

class CostAnalyticsTest < ActiveSupport::TestCase
  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rails.cache = @original_cache
  end

  def usage(**overrides)
    SessionTokenUsage.create!({
      request_id: "req_#{SecureRandom.hex(6)}",
      model: "claude-opus-5",
      agent_root: "zimmer",
      called_at: 2.hours.ago,
      input_tokens: 100,
      output_tokens: 200,
      cache_read_tokens: 10_000,
      cache_creation_tokens: 5_000,
      cache_creation_1h_tokens: 5_000
    }.merge(overrides))
  end

  test "the parts add up to the total" do
    # The page shows a total and a per-component breakdown side by side. They come
    # from different code paths — the total from SQL, the breakdown from Ruby over
    # grouped sums — so if they ever disagree the page contradicts itself.
    usage
    usage(model: "claude-sonnet-5", cache_creation_5m_tokens: 5_000, cache_creation_1h_tokens: 0)
    usage(model: "claude-haiku-4-5", cache_creation_1h_tokens: 0, cache_creation_5m_tokens: 0)
    AdhocTokenUsage.create!(
      request_id: "req_adhoc", source: "cli_status_probe", model: "claude-opus-5",
      called_at: 1.hour.ago, input_tokens: 5, output_tokens: 10, cache_read_tokens: 20_000
    )

    analytics = CostAnalytics.new(from: 7.days.ago)

    assert_in_delta analytics.totals[:cost_usd],
      analytics.cost_breakdown.sum { |r| r[:cost_usd] }, 0.000001
  end

  test "an unsplit cache write is priced the same by both paths" do
    # Rows that predate the `cache_creation` sub-object carry a total with no
    # split. SQL and Ruby must make the same 1-hour-rate assumption about them.
    usage(cache_creation_tokens: 1_000_000, cache_creation_5m_tokens: 0, cache_creation_1h_tokens: 0)

    analytics = CostAnalytics.new(from: 7.days.ago)

    assert_in_delta analytics.totals[:cost_usd],
      analytics.cost_breakdown.sum { |r| r[:cost_usd] }, 0.000001
  end

  test "the window is stable to the minute so a snapshot can be cached at all" do
    # `7.days.ago` carries sub-second precision. Left unrounded, every request
    # builds a different window and the cache can never hit.
    a = CostAnalytics.new(from: 7.days.ago)
    b = CostAnalytics.new(from: 7.days.ago)

    assert_equal a.cache_key, b.cache_key
    assert_equal 0, a.to.sec
    assert_equal 0, a.from.sec
  end

  test "a new usage row invalidates the snapshot" do
    usage
    analytics = CostAnalytics.new(from: 7.days.ago)
    assert_equal 1, analytics.snapshot[:totals][:api_calls]

    usage

    assert_equal 2, CostAnalytics.new(from: 7.days.ago).snapshot[:totals][:api_calls],
      "a row landing must change the cache key, or the page shows yesterday's number"
  end

  test "snapshot carries every section the page renders" do
    usage

    snapshot = CostAnalytics.new(from: 7.days.ago).snapshot

    assert_equal %i[totals cost_breakdown by_day by_agent_root by_model
                    by_thread_kind by_adhoc_source top_sessions unpriced_models].sort,
      snapshot.keys.sort
  end

  test "reports models it cannot price rather than counting them as free" do
    usage(model: "claude-imaginary-7")

    assert_equal [ "claude-imaginary-7" ], CostAnalytics.new(from: 7.days.ago).unpriced_models
  end

  test "rolls up by agent root, model and thread kind" do
    usage(agent_root: "zimmer-router")
    usage(agent_root: "issue-work-gate", subagent: true)

    analytics = CostAnalytics.new(from: 7.days.ago)

    assert_equal %w[issue-work-gate zimmer-router].sort,
      analytics.by_agent_root.map { |r| r[:agent_root] }.sort
    assert_equal %w[main subagent].sort, analytics.by_thread_kind.map { |r| r[:kind] }.sort
  end
end
