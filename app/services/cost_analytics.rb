# frozen_string_literal: true

# Rollups behind the Costs page, the REST endpoints, and the MCP tool.
#
# Every figure is computed in SQL over a time window. Nothing loads rows into
# Ruby to add them up — the usage tables grow by thousands of rows a day, and a
# year of history is millions.
#
# Money is applied at read time from TokenPricing, never stored. That is what
# lets this answer "re-price last month at today's rates" and "what would this
# have cost on Sonnet" without touching the data.
class CostAnalytics
  DEFAULT_WINDOW = 7.days

  # How many rows each breakdown returns before the tail is folded into "other".
  # The page is a summary, not an export; the REST index is the export.
  TOP_N = 15

  attr_reader :from, :to

  def initialize(from: nil, to: nil)
    @to = to || Time.current
    @from = from || (@to - DEFAULT_WINDOW)
  end

  def session_scope = SessionTokenUsage.in_window(from, to)
  def adhoc_scope = AdhocTokenUsage.in_window(from, to)

  # Headline numbers, both tables combined.
  def totals
    session = session_scope.totals
    adhoc = adhoc_scope.totals

    combined = session.merge(adhoc) { |_k, a, b| a + b }
    combined.merge(
      session_cost_usd: session[:cost_usd],
      adhoc_cost_usd: adhoc[:cost_usd]
    )
  end

  # Where the money goes by kind of token. This is the decomposition that makes
  # the bill legible: on this deployment cache WRITES are the largest single line
  # item, several times the cost of everything the models actually produced, and
  # a total alone never shows that.
  def cost_breakdown
    rates = both_tables_sum_by_component
    total = rates.values.sum
    rates.map do |component, cost|
      {
        component: component,
        cost_usd: cost,
        share: total.zero? ? 0.0 : (cost / total)
      }
    end.sort_by { |r| -r[:cost_usd] }
  end

  def by_day
    session = grouped(session_scope, day_expression)
    adhoc = grouped(adhoc_scope, day_expression)

    keys = (session.keys + adhoc.keys).uniq.sort
    keys.map do |day|
      s = session[day] || blank_row
      a = adhoc[day] || blank_row
      {
        day: day,
        cost_usd: s[:cost_usd] + a[:cost_usd],
        session_cost_usd: s[:cost_usd],
        adhoc_cost_usd: a[:cost_usd],
        tokens: s[:tokens] + a[:tokens],
        api_calls: s[:api_calls] + a[:api_calls]
      }
    end
  end

  def by_agent_root = top_rows(grouped(session_scope, "agent_root"), label: :agent_root)
  def by_model = top_rows(merge_grouped(grouped(session_scope, "model"), grouped(adhoc_scope, "model")), label: :model)
  def by_adhoc_source = top_rows(grouped(adhoc_scope, "source"), label: :source)

  # Main thread vs subagent. Useful for the "should this have been delegated"
  # question later — subagent spend is the cost side of that trade.
  def by_thread_kind
    rows = grouped(session_scope, "CASE WHEN subagent THEN 'subagent' ELSE 'main' END")
    rows.map { |kind, v| v.merge(kind: kind) }.sort_by { |r| -r[:cost_usd] }
  end

  # Top individual sessions. The join is left so a row whose session was deleted
  # still appears, labelled by its stored agent root.
  def top_sessions(limit: TOP_N)
    session_scope
      .where.not(session_id: nil)
      .group(:session_id)
      .order(SessionTokenUsage.cost_sum_sql.desc)
      .limit(limit)
      .pluck(:session_id, SessionTokenUsage.cost_sum_sql, SessionTokenUsage.total_tokens_sql, Arel.sql("COUNT(*)"))
      .map { |id, cost, tokens, calls| { session_id: id, cost_usd: cost.to_f, tokens: tokens.to_i, api_calls: calls.to_i } }
      .then { |rows| attach_session_titles(rows) }
  end

  # Models seen in the window that TokenPricing has no rate for. Surfaced rather
  # than swallowed: an unpriced model silently contributes zero to every total on
  # the page, so it has to be visible as something to fix.
  def unpriced_models
    models = (session_scope.distinct.pluck(:model) + adhoc_scope.distinct.pluck(:model)).uniq
    models.reject { |m| TokenPricing.priced?(m) }.sort
  end

  private

  def blank_row = { cost_usd: 0.0, tokens: 0, api_calls: 0 }

  def day_expression = "DATE(called_at)"

  # One GROUP BY, three aggregates, keyed by whatever expression is passed.
  def grouped(scope, expression)
    klass = scope.model
    scope
      .group(Arel.sql(expression))
      .pluck(Arel.sql(expression), klass.cost_sum_sql, klass.total_tokens_sql, Arel.sql("COUNT(*)"))
      .to_h { |key, cost, tokens, calls| [ key.to_s, { cost_usd: cost.to_f, tokens: tokens.to_i, api_calls: calls.to_i } ] }
  end

  def merge_grouped(a, b)
    (a.keys + b.keys).uniq.to_h do |key|
      x = a[key] || blank_row
      y = b[key] || blank_row
      [ key, { cost_usd: x[:cost_usd] + y[:cost_usd], tokens: x[:tokens] + y[:tokens], api_calls: x[:api_calls] + y[:api_calls] } ]
    end
  end

  def top_rows(hash, label:, limit: TOP_N)
    sorted = hash.reject { |k, _| k.blank? }.sort_by { |_, v| -v[:cost_usd] }
    head = sorted.first(limit).map { |key, v| v.merge(label => key) }
    tail = sorted.drop(limit)
    return head if tail.empty?

    head + [ {
      label => "other (#{tail.size})",
      cost_usd: tail.sum { |_, v| v[:cost_usd] },
      tokens: tail.sum { |_, v| v[:tokens] },
      api_calls: tail.sum { |_, v| v[:api_calls] }
    } ]
  end

  # Per-component cost across both tables. Each component is priced with the same
  # rate table the row totals use, so the parts always add to the whole.
  def both_tables_sum_by_component
    components = Hash.new(0.0)

    [ SessionTokenUsage.in_window(from, to), AdhocTokenUsage.in_window(from, to) ].each do |scope|
      scope.group(:model).pluck(
        :model,
        Arel.sql("COALESCE(SUM(input_tokens), 0)"),
        Arel.sql("COALESCE(SUM(output_tokens), 0)"),
        Arel.sql("COALESCE(SUM(cache_read_tokens), 0)"),
        Arel.sql("COALESCE(SUM(cache_creation_5m_tokens), 0)"),
        Arel.sql("COALESCE(SUM(cache_creation_1h_tokens), 0)"),
        Arel.sql("COALESCE(SUM(CASE WHEN cache_creation_5m_tokens + cache_creation_1h_tokens = 0 THEN cache_creation_tokens ELSE 0 END), 0)"),
        Arel.sql("COALESCE(SUM(web_search_requests), 0)")
      ).each do |model, input, output, read, write_5m, write_1h, write_unsplit, searches|
        rate = TokenPricing.rate_for(model)
        components["fresh input"] += input.to_i * rate.input / 1_000_000.0
        components["output"] += output.to_i * rate.output / 1_000_000.0
        components["cache read"] += read.to_i * rate.cache_read / 1_000_000.0
        components["cache write (5m)"] += write_5m.to_i * rate.cache_write_5m / 1_000_000.0
        components["cache write (1h)"] += (write_1h.to_i + write_unsplit.to_i) * rate.cache_write_1h / 1_000_000.0
        components["web search"] += searches.to_i * TokenPricing::WEB_SEARCH_PER_1K_REQUESTS / 1_000.0
      end
    end

    components.reject { |_, v| v.zero? }
  end

  def attach_session_titles(rows)
    titles = Session.where(id: rows.map { |r| r[:session_id] }).pluck(:id, :title).to_h
    rows.map { |r| r.merge(title: titles[r[:session_id]]) }
  end
end
