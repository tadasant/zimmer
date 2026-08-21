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
                    by_thread_kind by_adhoc_source by_feature top_sessions unpriced_models].sort,
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
  test "a feature table total is refused rather than answered wrongly" do
    # Several feature rows describe ONE API call, so a naive `totals` would report
    # an api_calls figure inflated by the number of features detected. A wrong
    # total reads as authoritative; refusing does not.
    assert_raises(NotImplementedError) { TokenUsageFeature.totals }
  end

  # TOP_N is a constant on purpose — the page is a summary, not an export — so a
  # test that needs the fold has to narrow it rather than seed sixteen roots.
  def stub_const_top_n(value)
    original = CostAnalytics::TOP_N
    CostAnalytics.send(:remove_const, :TOP_N)
    CostAnalytics.const_set(:TOP_N, value)
    yield
  ensure
    CostAnalytics.send(:remove_const, :TOP_N)
    CostAnalytics.const_set(:TOP_N, original)
  end

  def feature_row(record, feature, **volumes)
    TokenUsageFeature.create!({
      request_id: record.request_id, feature: feature, session_id: record.session_id,
      agent_root: record.agent_root, model: record.model, subagent: record.subagent,
      called_at: record.called_at
    }.merge(volumes))
  end

  test "the feature breakdown states the share it could not account for" do
    # The residual is the point of the shape. Without it a 40%-covered estimate
    # reads as a complete one, and a feature gets cut on a number that was never
    # the whole picture.
    record = usage(cache_read_tokens: 100_000, cache_creation_tokens: 0,
                   cache_creation_1h_tokens: 0, input_tokens: 0, output_tokens: 0)
    feature_row(record, "goal", cache_read_tokens: 25_000)

    breakdown = CostAnalytics.new(from: 1.day.ago).by_feature

    assert_equal 1, breakdown[:rows].length
    assert_equal "goal", breakdown[:rows].first[:feature]
    assert_in_delta 0.25, breakdown[:coverage], 0.001
    assert_in_delta 75_000, breakdown[:residual_tokens], 1
    assert_operator breakdown[:residual_cost_usd], :>, 0
    assert_in_delta breakdown[:total_cost_usd],
      breakdown[:rows].sum { |r| r[:cost_usd] } + breakdown[:residual_cost_usd], 0.001
  end

  test "a feature's dollars and its tokens can rank differently, and both are reported" do
    # Cache position, priced. Identical token volumes in different buckets are
    # different money — that divergence is the whole reason to price the split
    # rather than count it.
    written = usage(cache_read_tokens: 0, cache_creation_tokens: 100_000,
                    cache_creation_1h_tokens: 100_000, input_tokens: 0, output_tokens: 0)
    read = usage(cache_read_tokens: 100_000, cache_creation_tokens: 0,
                 cache_creation_1h_tokens: 0, input_tokens: 0, output_tokens: 0)
    feature_row(written, "goal", cache_creation_tokens: 100_000, cache_creation_1h_tokens: 100_000)
    feature_row(read, "skill_body", cache_read_tokens: 100_000)

    rows = CostAnalytics.new(from: 1.day.ago).by_feature[:rows]
    goal = rows.find { |r| r[:feature] == "goal" }
    skill = rows.find { |r| r[:feature] == "skill_body" }

    assert_equal goal[:tokens], skill[:tokens], "same volume"
    assert_operator goal[:cost_usd], :>, skill[:cost_usd] * 10,
      "a cache write bills at 2x base input, a cache read at a tenth"
  end

  test "the feature breakdown can be scoped to one agent root" do
    mine = usage(agent_root: "zimmer-router")
    theirs = usage(agent_root: "issue-work-gate")
    feature_row(mine, "goal", cache_read_tokens: 5_000)
    feature_row(theirs, "goal", cache_read_tokens: 90_000)

    scoped = CostAnalytics.new(from: 1.day.ago).feature_breakdown(agent_root: "zimmer-router")

    assert_equal 1, scoped[:rows].length
    assert_equal 5_000, scoped[:rows].first[:tokens]
  end

  test "each agent-root row carries its own feature split for the drilldown" do
    record = usage(agent_root: "zimmer-router")
    feature_row(record, "goal", cache_read_tokens: 5_000)

    row = CostAnalytics.new(from: 1.day.ago).by_agent_root.find { |r| r[:agent_root] == "zimmer-router" }

    assert_equal [ "goal" ], row[:features].map { |f| f[:feature] }
  end

  test "each day carries the breakdown the chart reveals on hover" do
    usage(agent_root: "zimmer-router", called_at: 3.hours.ago)
    usage(agent_root: "issue-work-gate", model: "claude-sonnet-5", called_at: 3.hours.ago)

    day = CostAnalytics.new(from: 1.day.ago).by_day.last

    assert_equal %w[zimmer-router issue-work-gate].sort, day[:roots].map { |r| r[:name] }.sort
    assert_equal %w[claude-opus-5 claude-sonnet-5].sort, day[:models].map { |m| m[:name] }.sort
  end

  test "the feature table refuses to be asked for call totals" do
    # Several rows describe one API call, so `api_calls` off this table would be
    # inflated by the number of features detected. Refusing beats a wrong number
    # that reads as authoritative.
    assert_raises(NotImplementedError) { TokenUsageFeature.totals }
  end

  test "the folded other-roots row carries the feature split of what it swallowed" do
    # `top_rows` folds the tail into a synthetic "other (N)" row, which is not a
    # real agent_root and so has no bucket of its own. Opening it must not reveal
    # an empty panel.
    stub_const_top_n(1) do
      big = usage(agent_root: "zimmer-router", cache_read_tokens: 500_000)
      small = usage(agent_root: "issue-work-gate", cache_read_tokens: 100_000)
      feature_row(big, "goal", cache_read_tokens: 100_000)
      feature_row(small, "mcp_result", cache_read_tokens: 40_000)

      rows = CostAnalytics.new(from: 1.day.ago).by_agent_root
      folded = rows.last

      assert_match(/\Aother \(/, folded[:agent_root])
      assert_equal [ "mcp_result" ], folded[:features].map { |f| f[:feature] }
    end
  end

  test "a custom window keeps the last minute of its end day" do
    # CostWindow hands over an end_of_day; rounding both ends DOWN to the minute
    # would silently drop calls in the final 59 seconds of a range someone typed.
    late = Time.zone.parse("2026-03-11 23:59:30")
    usage(called_at: late)

    window = CostWindow.from_params(from: "2026-03-09", to: "2026-03-11")

    assert_equal 1, CostAnalytics.new(from: window.from, to: window.to).totals[:api_calls]
  end

  test "a window with no attribution still reports a total and a full residual" do
    usage

    breakdown = CostAnalytics.new(from: 1.day.ago).by_feature

    assert_empty breakdown[:rows]
    assert_equal 0.0, breakdown[:coverage]
    assert_in_delta breakdown[:total_cost_usd], breakdown[:residual_cost_usd], 0.001
  end
end
