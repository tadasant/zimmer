# frozen_string_literal: true

# One GROUP BY over a usage table that sums plain token columns per group AND per
# model, and prices the result in Ruby.
#
# Pricing is linear in every token column once the model is fixed, so pricing a
# (group, model) sum is exactly pricing each row and adding them up. That is the
# whole trick, and it is what keeps a long window inside the proxy timeout:
# `TokenPricing.cost_sql` evaluated per row is five `POSITION(LOWER(model))`
# matches and a dozen numeric multiplies on every row of every query, and over a
# 90-day window that expression costs several times what the scan does. Here it
# runs once per (group, model) pair, which is thousands of times, not millions.
#
# The one non-linear piece of the row price is the unsplit cache write (a row
# with no 5m/1h split is charged at the 1-hour rate), so it is summed as its own
# column. `TokenPricing.cost_for` makes the same assumption per row, and
# test/services/cost_rollup_test.rb holds the two paths to the same figure.
#
# Every caller reads a rollup through `fold`, so one query can serve as many
# breakdowns as can be derived from its grouping.
class CostRollup
  # Summed per (group, model). `cache_write_unsplit` is the part of
  # `cache_creation_tokens` on rows with no 5m/1h split.
  TOKEN_SUMS = %i[
    input_tokens output_tokens cache_read_tokens cache_creation_tokens
    cache_creation_5m_tokens cache_creation_1h_tokens
  ].freeze
  SERVER_TOOL_SUMS = %i[web_search_requests web_fetch_requests].freeze

  # The shape every fold returns: TokenAccounting#totals plus nothing else, so a
  # folded bucket and `relation.totals` are interchangeable.
  TOTAL_KEYS = (TokenAccounting::SUMMED_COLUMNS + %i[api_calls cost_usd total_tokens]).freeze

  # `cost_usd` is priced once, when the row is read, because every fold that
  # touches the row needs it and a per-session rollup is thousands of rows.
  Row = Data.define(:keys, :model, :sums, :cost_usd)

  # @param relation [ActiveRecord::Relation] an already-narrowed window of one of
  #   TokenPricing::PRICEABLE_TABLES
  # @param expressions [Array<String>] SQL expressions to group by, besides model.
  #   Constants from the caller, never user input.
  def initialize(relation, *expressions)
    @relation = relation
    @expressions = expressions
    @table = relation.model.table_name
    @server_tools = TokenPricing::PRICEABLE_TABLES.fetch(@table)
  end

  # One query, memoized.
  def rows
    @rows ||= begin
      sums = summed_columns
      selects = @expressions.map { |e| Arel.sql(e) } +
        [ Arel.sql("#{@table}.model") ] +
        sums.map { |_, sql| Arel.sql(sql) }

      @relation
        .unscope(:order)
        .group(*@expressions.map { |e| Arel.sql(e) }, Arel.sql("#{@table}.model"))
        .pluck(*selects)
        .map do |values|
          keys = values.first(@expressions.size)
          model = values[@expressions.size]
          figures = sums.keys.zip(values.drop(@expressions.size + 1)).to_h
          Row.new(keys: keys, model: model, sums: figures, cost_usd: components_for(model, figures).values.sum)
        end
    end
  end

  # Rows bucketed by whatever the block returns, each bucket in TOTAL_KEYS shape.
  # A block returning nil drops the row.
  def fold
    buckets = {}
    rows.each do |row|
      key = yield(*row.keys, row.model)
      next if key.nil?

      add(buckets[key] ||= self.class.blank, row)
    end
    buckets
  end

  # Every row in one bucket.
  def total = fold { :all }.fetch(:all) { self.class.blank }

  def models = rows.map(&:model).uniq

  # What one row cost, split by kind of token — the decomposition behind the
  # Costs page's "where the money goes".
  def components(row) = components_for(row.model, row.sums)

  def self.blank = TOTAL_KEYS.index_with { |k| k == :cost_usd ? 0.0 : 0 }

  private

  def components_for(model, s)
    rate = (@rates ||= {})[model] ||= TokenPricing.rate_for(model)
    {
      "fresh input" => s[:input_tokens] * rate.input / 1_000_000.0,
      "output" => s[:output_tokens] * rate.output / 1_000_000.0,
      "cache read" => s[:cache_read_tokens] * rate.cache_read / 1_000_000.0,
      "cache write (5m)" => s[:cache_creation_5m_tokens] * rate.cache_write_5m / 1_000_000.0,
      "cache write (1h)" => (s[:cache_creation_1h_tokens] + s[:cache_write_unsplit]) * rate.cache_write_1h / 1_000_000.0,
      "web search" => s.fetch(:web_search_requests, 0) * TokenPricing::WEB_SEARCH_PER_1K_REQUESTS / 1_000.0
    }
  end

  def add(bucket, row)
    s = row.sums
    TokenAccounting::SUMMED_COLUMNS.each { |c| bucket[c] += s.fetch(c, 0) }
    bucket[:api_calls] += s[:api_calls]
    bucket[:total_tokens] += TokenAccounting::VOLUME_COLUMNS.sum { |c| s[c] }
    bucket[:cost_usd] += row.cost_usd
  end

  def summed_columns
    columns = TOKEN_SUMS + (@server_tools ? SERVER_TOOL_SUMS : [])
    # Cast back to bigint: SUM over bigint is `numeric`, which the driver hands
    # back as BigDecimal, and casting thousands of those cost as much as the scan.
    # No group comes near 2^63 tokens.
    sums = columns.to_h { |c| [ c, "COALESCE(SUM(#{@table}.#{c}), 0)::bigint" ] }
    sums[:cache_write_unsplit] =
      "COALESCE(SUM(CASE WHEN #{@table}.cache_creation_5m_tokens + #{@table}.cache_creation_1h_tokens = 0 " \
      "THEN #{@table}.cache_creation_tokens ELSE 0 END), 0)::bigint"
    sums[:api_calls] = "COUNT(*)"
    sums
  end
end
