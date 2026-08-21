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

  # Ingestion runs every 10 minutes, so a snapshot is stale for at most one cycle
  # even when nothing invalidates the key.
  CACHE_TTL = 10.minutes

  # How many rows each breakdown returns before the tail is folded into "other".
  # The page is a summary, not an export; the REST index is the export.
  TOP_N = 15

  attr_reader :from, :to

  def initialize(from: nil, to: nil)
    # BOTH ends round down to the minute, including one the caller supplied.
    # `7.days.ago` carries sub-second precision, so a window built from it moves
    # every request: it can never be cached, never be compared between two
    # requests, and never be reproduced by someone checking a figure. Nobody
    # reading a spend page needs the last few seconds.
    # The START rounds DOWN and the END rounds UP, both to the minute. Rounding
    # both down would drop the final partial minute — which for a calendar range
    # is the last 59 seconds of the end day, since CostWindow hands over an
    # end_of_day and `in_window` is inclusive. Nobody reading a spend page needs
    # the last few seconds, but silently excluding them from a range someone
    # typed is a different thing from not showing them.
    given_to = to || Time.current
    @to = given_to.change(sec: 0, usec: 0)
    @to += 1.minute if @to < given_to
    @from = (from || (@to - DEFAULT_WINDOW)).change(sec: 0, usec: 0)
  end

  # Everything the Costs page and the REST rollup endpoint render, in one
  # memoizable bundle.
  #
  # There are a dozen separate aggregates here and each one scans the window. That
  # is fine at a week and ruinous at a year: this table grows by thousands of rows
  # a day, so a 365-day window is millions of rows read a dozen times over, per
  # request, by every viewer. Computing them together and caching the result makes
  # the expensive case pay once per ingestion cycle instead of once per page view.
  def snapshot
    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
      {
        totals: totals,
        cost_breakdown: cost_breakdown,
        by_day: by_day,
        by_agent_root: by_agent_root,
        by_model: by_model,
        by_thread_kind: by_thread_kind,
        by_adhoc_source: by_adhoc_source,
        by_feature: by_feature,
        top_sessions: top_sessions,
        unpriced_models: unpriced_models
      }
    end
  end

  # `MAX(id)` is an index lookup, not a scan, and it changes the moment ingestion
  # writes anything — so the key turns over exactly when the numbers do rather
  # than on a timer alone. The TTL is the backstop for a row deleted rather than
  # added, which moves no maximum.
  def cache_key
    [
      "cost-analytics/v2", from.to_i, to.to_i,
      SessionTokenUsage.maximum(:id).to_i, AdhocTokenUsage.maximum(:id).to_i,
      TokenUsageFeature.maximum(:id).to_i
    ].join("/")
  end

  def session_scope = SessionTokenUsage.in_window(from, to)
  def adhoc_scope = AdhocTokenUsage.in_window(from, to)
  def feature_scope = TokenUsageFeature.in_window(from, to)

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

  # The daily series, each day carrying the breakdown behind it.
  #
  # `roots` and `models` are what the chart reveals when a bar is hovered or
  # tapped: a total alone says spend doubled on Tuesday, not who doubled it. Both
  # come from ONE extra grouped query each over the same window, rather than a
  # query per bar — at a year the chart is 365 bars, and a per-bar query would be
  # 365 round trips per page view.
  def by_day
    session = grouped(session_scope, day_expression)
    adhoc = grouped(adhoc_scope, day_expression)
    roots = nested(session_scope, day_expression, "agent_root")
    models = nested(session_scope, day_expression, "model")

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
        api_calls: s[:api_calls] + a[:api_calls],
        roots: top_pairs(roots[day]),
        models: top_pairs(models[day])
      }
    end
  end

  # Each row carries the feature split behind it, because "this root cost $40" is
  # not yet a decision — "$18 of this root's $40 was the goal block Zimmer appends
  # to every turn" is. That is the drilldown the whole feature table exists for,
  # and the agent-root breakdown is where it earns its keep.
  def by_agent_root
    grouped_roots = grouped(session_scope, "agent_root")
    rows = top_rows(grouped_roots, label: :agent_root)
    features = nested(feature_scope, "agent_root", "feature")

    # The folded "other (N)" row is not a root, so it has no bucket of its own.
    # Summing the roots it swallowed keeps its drilldown as informative as every
    # other row's, rather than opening onto nothing.
    folded = rows.last&.dig(:agent_root).to_s.start_with?("other (")
    tail_keys = folded ? grouped_roots.keys - rows.map { |r| r[:agent_root] } : []

    rows.map do |row|
      bucket = if folded && row.equal?(rows.last)
        tail_keys.each_with_object(Hash.new { |h, k| h[k] = blank_row }) do |key, merged|
          (features[key] || {}).each do |feature, value|
            merged[feature] = {
              cost_usd: merged[feature][:cost_usd] + value[:cost_usd],
              tokens: merged[feature][:tokens] + value[:tokens],
              api_calls: merged[feature][:api_calls] + value[:api_calls]
            }
          end
        end
      else
        features[row[:agent_root]]
      end

      row.merge(features: top_pairs(bucket, limit: 6, label: :feature))
    end
  end
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

  # Where the money went by context-management feature, with the residual it could
  # not account for stated as its own line.
  #
  # Every figure here is an ESTIMATE — the API reports per-request totals with no
  # per-feature decomposition, so the split is derived from transcript content by
  # ContextFeatureAttributor. The residual is the point of the shape: it is what
  # the transcript never sees (the system prompt, the tool schemas) plus the
  # per-request server-tool charges no content feature can claim. On this
  # deployment it is the largest single line, and saying so is the difference
  # between an honest estimate and a confident wrong one.
  #
  # `tokens` and `cost_usd` are BOTH returned and will not rank the same way.
  # Cache writes bill at up to 2x base input and cache reads at a tenth, so a
  # feature re-appended to every turn and one that lands once in the prefix can
  # move identical volumes for very different money. Dollars is the column that
  # answers "is this worth it"; tokens is the one that answers "how big is it".
  def by_feature
    attributed = grouped(feature_scope, "feature").map { |key, v| v.merge(feature: key) }
    attributed.sort_by! { |r| -r[:cost_usd] }

    session = session_scope.totals
    residual_cost = session[:cost_usd] - attributed.sum { |r| r[:cost_usd] }
    residual_tokens = session[:total_tokens] - attributed.sum { |r| r[:tokens] }

    {
      rows: attributed,
      attributed_cost_usd: attributed.sum { |r| r[:cost_usd] },
      attributed_tokens: attributed.sum { |r| r[:tokens] },
      total_cost_usd: session[:cost_usd],
      total_tokens: session[:total_tokens],
      residual_cost_usd: [ residual_cost, 0.0 ].max,
      residual_tokens: [ residual_tokens, 0 ].max,
      coverage: session[:total_tokens].positive? ? (attributed.sum { |r| r[:tokens] }.to_f / session[:total_tokens]) : 0.0
    }
  end

  # The feature split for one agent root or one session, for a drilldown that has
  # already narrowed. Same shape as `by_feature`, scoped.
  def feature_breakdown(agent_root: nil, session_id: nil)
    features = feature_scope
    usage = session_scope
    if agent_root.present?
      features = features.for_agent_root(agent_root)
      usage = usage.for_agent_root(agent_root)
    end
    if session_id.present?
      features = features.where(session_id: session_id)
      usage = usage.where(session_id: session_id)
    end

    attributed = grouped(features, "feature").map { |key, v| v.merge(feature: key) }.sort_by { |r| -r[:cost_usd] }
    totals = usage.totals

    {
      rows: attributed,
      total_cost_usd: totals[:cost_usd],
      total_tokens: totals[:total_tokens],
      residual_cost_usd: [ totals[:cost_usd] - attributed.sum { |r| r[:cost_usd] }, 0.0 ].max,
      residual_tokens: [ totals[:total_tokens] - attributed.sum { |r| r[:tokens] }, 0 ].max,
      coverage: totals[:total_tokens].positive? ? (attributed.sum { |r| r[:tokens] }.to_f / totals[:total_tokens]) : 0.0
    }
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

  # One GROUP BY over two expressions, returned as outer key => inner key => row.
  # This is how a per-bar drilldown stays one query instead of one per bar.
  def nested(scope, outer, inner)
    klass = scope.model
    result = Hash.new { |h, k| h[k] = {} }

    scope
      .group(Arel.sql(outer), Arel.sql(inner))
      .pluck(Arel.sql(outer), Arel.sql(inner), klass.cost_sum_sql, klass.total_tokens_sql, Arel.sql("COUNT(*)"))
      .each do |outer_key, inner_key, cost, tokens, calls|
        result[outer_key.to_s][inner_key.to_s] = { cost_usd: cost.to_f, tokens: tokens.to_i, api_calls: calls.to_i }
      end

    result
  end

  # The biggest few contributors from a `nested` bucket, as a flat list a view can
  # render. Bounded because this is a tooltip, not a table.
  def top_pairs(bucket, limit: 4, label: :name)
    return [] if bucket.blank?

    bucket
      .reject { |k, _| k.blank? }
      .sort_by { |_, v| -v[:cost_usd] }
      .first(limit)
      .map { |k, v| v.merge(label => k) }
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
