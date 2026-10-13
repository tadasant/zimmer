# frozen_string_literal: true

require "test_helper"

class CostRollupTest < ActiveSupport::TestCase
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

  # Every row shape the price has a branch for: each family, an unpriced model,
  # a split and an unsplit cache write, a web search.
  def mixed_rows
    usage
    usage(model: "claude-sonnet-5", cache_creation_5m_tokens: 3_000, cache_creation_1h_tokens: 2_000)
    usage(model: "claude-haiku-4-5-20251001", cache_creation_tokens: 1_000_000, cache_creation_1h_tokens: 0)
    usage(model: "claude-fable-5-1", agent_root: "motet", web_search_requests: 7)
    usage(model: "claude-imaginary-7", web_search_requests: 3)
  end

  test "pricing a (group, model) sum in Ruby matches pricing every row in SQL" do
    # The whole rollup rests on this: cost is linear in every token column once
    # the model is fixed, except the unsplit cache write, which is summed on its
    # own. If the two paths ever disagree, every figure on the Costs page moves.
    mixed_rows

    rollup = CostRollup.new(SessionTokenUsage.all, "agent_root")
    sql = SessionTokenUsage.all.totals

    assert_in_delta sql[:cost_usd], rollup.total[:cost_usd], 1e-9
    (TokenAccounting::SUMMED_COLUMNS + %i[api_calls total_tokens]).each do |column|
      assert_equal sql[column], rollup.total[column], column.to_s
    end
  end

  test "each folded bucket matches the SQL price of the same slice" do
    mixed_rows

    by_root = CostRollup.new(SessionTokenUsage.all, "agent_root").fold { |root, _model| root }

    %w[zimmer motet].each do |root|
      assert_in_delta SessionTokenUsage.for_agent_root(root).totals[:cost_usd], by_root[root][:cost_usd], 1e-9
    end
  end

  test "the feature table is priced without server-tool charges, as its SQL price is" do
    parent = usage
    TokenUsageFeature.create!(
      request_id: parent.request_id, feature: "goal", model: "claude-opus-5", agent_root: "zimmer",
      called_at: parent.called_at, input_tokens: 10, cache_read_tokens: 4_000, cache_creation_tokens: 900
    )

    rollup = CostRollup.new(TokenUsageFeature.all, "feature")
    sql = TokenUsageFeature.group(:feature).pluck(:feature, TokenUsageFeature.cost_sum_sql).to_h

    assert_in_delta sql["goal"].to_f, rollup.fold { |feature, _model| feature }["goal"][:cost_usd], 1e-9
  end

  test "the rollup is one query however many times it is folded" do
    mixed_rows
    rollup = CostRollup.new(SessionTokenUsage.all, "agent_root")

    queries = count_queries do
      rollup.total
      rollup.fold { |root, _| root }
      rollup.fold { |_, model| model }
      rollup.models
    end

    assert_equal 1, queries
  end

  private

  def count_queries(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveRecord::Base.uncached { ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block) }
    count
  end
end
