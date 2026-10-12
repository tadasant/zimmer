# frozen_string_literal: true

# Rollups behind the Costs page, the REST endpoints, and the MCP tool.
#
# Token volumes are summed in SQL over a time window; nothing loads usage rows
# into Ruby to add them up — the usage tables grow by thousands of rows a day,
# and a year of history is millions.
#
# The whole report is FIVE grouped scans (see the rollups below), each summing
# plain token columns per (group, model), with dollars applied in Ruby by
# CostRollup. Every section is folded out of those five. A section with its own
# query, or one that prices rows in SQL, multiplies the cost of a long window
# past the proxy timeout — test/services/cost_analytics_test.rb pins the shape.
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

  attr_reader :from, :to, :scope

  # @param scope [CostScope] which slice of the ledger every figure covers. The
  #   default is the whole fleet, which is what the page rendered before it could
  #   be narrowed and what `get_costs` still answers with no arguments.
  def initialize(from: nil, to: nil, scope: CostScope.new)
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
    @scope = scope
  end

  # Everything the Costs page and the REST rollup endpoint render, in one
  # memoizable bundle.
  #
  # Five grouped scans of the window, each of which reads every row in it. At a
  # year that is millions of rows read five times over, so the bundle is cached:
  # the expensive case pays once per ingestion cycle instead of once per viewer.
  def snapshot
    Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
      {
        totals: totals,
        cost_breakdown: cost_breakdown,
        by_day: by_day,
        by_agent_root: by_agent_root,
        by_model: by_model,
        by_thread_kind: by_thread_kind,
        by_runtime: by_runtime,
        by_adhoc_source: by_adhoc_source,
        by_feature: by_feature,
        by_experiment: by_experiment,
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
      # The scope is part of the key, not a filter applied after it. Leave it out
      # and a page narrowed to one agent root reads the fleet's cached snapshot
      # back under the root's heading — every figure wrong, nothing to show for it.
      "cost-analytics/v6", scope.cache_token, from.to_i, to.to_i,
      SessionTokenUsage.maximum(:id).to_i, AdhocTokenUsage.maximum(:id).to_i,
      TokenUsageFeature.maximum(:id).to_i,
      # `updated_at`, not `id`: a session's SECOND observation is an update, so a
      # flag moving on -> mixed changes the report without inserting anything.
      # One row per session per setting, so the max is a scan of thousands, not
      # of the millions the usage tables hold.
      SessionExperimentalFlag.maximum(:updated_at).to_i
    ].join("/")
  end

  def session_scope = scope.narrow(SessionTokenUsage.in_window(from, to))
  def adhoc_scope = scope.narrow_adhoc(AdhocTokenUsage.in_window(from, to))
  def feature_scope = scope.narrow(TokenUsageFeature.in_window(from, to))

  # The denominator for feature ATTRIBUTION, which is a narrower population than
  # spend. ContextFeatureAttributor measures Claude Code's context-management
  # machinery — the goal block, the skill bodies, the tool results — by reading a
  # Claude transcript, so only Claude Code rows can ever have a `token_usage_features`
  # row to be attributed BY. Dividing attributed tokens by every runtime's tokens
  # would make `coverage` fall and the residual grow purely as a function of Pi
  # and Codex volume, which the page would read as "attribution is degrading"
  # when nothing about attribution had changed. `quota_bearing` is the same
  # predicate for a different reason and they are deliberately not shared: this
  # one would still be right if Pi spent against an Anthropic window, and that
  # one would still be right if Pi grew a feature attributor.
  def attributable_scope = session_scope.where(agent_runtime: ClaudeAuthProvider::RUNTIME)

  # Headline numbers, both tables combined.
  def totals
    session = usage_rollup.total
    adhoc = adhoc_rollup.total

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
    rates = Hash.new(0.0)
    [ usage_rollup, adhoc_rollup ].each do |rollup|
      rollup.rows.each { |row| rollup.components(row).each { |component, cost| rates[component] += cost } }
    end
    rates.reject! { |_, cost| cost.zero? }
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
  # come out of the same (day, agent root, model) rollup as the bars themselves,
  # rather than a query per bar — at a year the chart is 365 bars, and a per-bar
  # query would be 365 round trips per page view.
  def by_day
    session = slim(daily_rollup.fold { |day, _root, _model| day.to_s })
    adhoc = slim(adhoc_rollup.fold { |day, _source, _model| day.to_s })
    roots = nest(daily_rollup.fold { |day, root, _model| [ day.to_s, root.to_s ] })
    models = nest(daily_rollup.fold { |day, _root, model| [ day.to_s, model.to_s ] })

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
    grouped_roots = slim(usage_rollup.fold { |root, _runtime, _subagent, _model| root.to_s })
    rows = top_rows(grouped_roots, label: :agent_root)
    features = nest(feature_rollup.fold { |root, feature, _model| [ root.to_s, feature.to_s ] })

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
  def by_model
    session = slim(usage_rollup.fold { |*, model| model.to_s })
    adhoc = slim(adhoc_rollup.fold { |*, model| model.to_s })
    top_rows(merge_grouped(session, adhoc), label: :model)
  end

  def by_adhoc_source = top_rows(slim(adhoc_rollup.fold { |_day, source, _model| source.to_s }), label: :source)

  # Main thread vs subagent. Useful for the "should this have been delegated"
  # question later — subagent spend is the cost side of that trade.
  def by_thread_kind
    rows = slim(usage_rollup.fold { |_root, _runtime, subagent, _model| subagent ? "subagent" : "main" })
    rows.map { |kind, v| v.merge(kind: kind) }.sort_by { |r| -r[:cost_usd] }
  end

  # Spend by agent runtime — which is spend by BILLING RELATIONSHIP, and that is
  # why it is worth a row of its own rather than being left implicit in the
  # by-model table.
  #
  # A `claude_code` row is subscription spend: a list-price figure, comparable
  # across models, and not money owed. A `codex` row is the same, against a
  # ChatGPT plan — and priced at zero today, because TokenPricing carries no
  # OpenAI rates. A `pi` row is a metered OpenRouter invoice, which IS money
  # owed. Every other total on this page adds the three together — correctly,
  # since all of them are spend — so without this split a reader has no way to
  # tell what share of a number is an actual bill, or how much of it is a
  # runtime priced at zero.
  def by_runtime
    rows = slim(usage_rollup.fold { |_root, runtime, _subagent, _model| runtime.to_s })
    rows.map { |runtime, v| v.merge(runtime: runtime) }.sort_by { |r| -r[:cost_usd] }
  end

  # Top individual sessions. A session that was deleted still appears, with no
  # title, because its usage rows outlive it.
  def top_sessions(limit: TOP_N)
    slim(session_rollup.fold { |session_id, _root, _model| session_id })
      .sort_by { |id, v| [ -v[:cost_usd], id ] }
      .first(limit)
      .map { |id, v| v.merge(session_id: id) }
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
    attributed = slim(feature_rollup.fold { |_root, feature, _model| feature.to_s }).map { |key, v| v.merge(feature: key) }
    attributed.sort_by! { |r| -r[:cost_usd] }

    session = usage_rollup.fold { |_root, runtime, _subagent, _model| :all if runtime == ClaudeAuthProvider::RUNTIME }
      .fetch(:all) { CostRollup.blank }
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

  # What each experimental setting looks like to have done to spend, with every
  # reason not to trust it attached.
  #
  # This is the crude A/B test Zimmer can actually run: the settings are global
  # and the cohorts are whoever ran while each one was on, so the comparison is
  # observational and — for a setting backfilled from the date it landed —
  # purely temporal. ExperimentAnalytics documents what it does about that and
  # what it cannot. The view is expected to print the caveats next to the number,
  # not underneath a fold.
  def by_experiment = ExperimentAnalytics.new(session_scope, per_session: session_rollup).reports

  # The feature split for one agent root or one session, for a drilldown that has
  # already narrowed. Same shape as `by_feature`, scoped.
  def feature_breakdown(agent_root: nil, session_id: nil)
    features = feature_scope
    usage = attributable_scope
    if agent_root.present?
      features = features.for_agent_root(agent_root)
      usage = usage.for_agent_root(agent_root)
    end
    if session_id.present?
      features = features.where(session_id: session_id)
      usage = usage.where(session_id: session_id)
    end

    attributed = slim(CostRollup.new(features, "feature").fold { |feature, _model| feature.to_s })
      .map { |key, v| v.merge(feature: key) }.sort_by { |r| -r[:cost_usd] }
    totals = CostRollup.new(usage).total

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
    models = (usage_rollup.models + adhoc_rollup.models).uniq
    models.reject { |m| TokenPricing.priced?(m) }.sort
  end

  private

  def blank_row = { cost_usd: 0.0, tokens: 0, api_calls: 0 }

  def day_expression = "DATE(called_at)"

  # The five scans. Each one is the narrowest grouping that still answers every
  # section folded out of it, because the cost of a GROUP BY is set by how many
  # groups it holds as much as by how many rows it reads: one grouping fine
  # enough to answer everything — day x root x runtime x thread x session — has
  # more groups than the window has rows, and took longer than the twelve
  # queries it would have replaced.
  #
  # Totals, the token-kind split, and the root / model / thread / runtime tables.
  def usage_rollup = @usage_rollup ||= CostRollup.new(session_scope, "agent_root", "agent_runtime", "subagent")
  # The daily chart and what each bar reveals on hover.
  def daily_rollup = @daily_rollup ||= CostRollup.new(session_scope, day_expression, "agent_root")
  # Top sessions, and the per-session figures the experiment cohorts are made of.
  def session_rollup = @session_rollup ||= CostRollup.new(session_scope.where.not(session_id: nil), "session_id", "agent_root")
  def adhoc_rollup = @adhoc_rollup ||= CostRollup.new(adhoc_scope, day_expression, "source")
  def feature_rollup = @feature_rollup ||= CostRollup.new(feature_scope, "agent_root", "feature")

  # A fold in the three-figure shape every breakdown row carries.
  def slim(folded)
    folded.transform_values { |v| { cost_usd: v[:cost_usd], tokens: v[:total_tokens], api_calls: v[:api_calls] } }
  end

  # A fold keyed by [outer, inner], as outer key => inner key => row. This is how
  # a per-bar drilldown stays one query instead of one per bar.
  def nest(folded)
    slim(folded).each_with_object(Hash.new { |h, k| h[k] = {} }) do |((outer, inner), row), result|
      result[outer][inner] = row
    end
  end

  # The biggest few contributors from a `nested` bucket, as a flat list a view can
  # render. Bounded because this is a tooltip, not a table.
  def top_pairs(bucket, limit: 4, label: :name)
    return [] if bucket.blank?

    bucket
      .reject { |k, _| k.blank? }
      .sort_by { |k, v| [ -v[:cost_usd], k ] }
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
    sorted = hash.reject { |k, _| k.blank? }.sort_by { |k, v| [ -v[:cost_usd], k ] }
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

  def attach_session_titles(rows)
    titles = Session.where(id: rows.map { |r| r[:session_id] }).pluck(:id, :title).to_h
    rows.map { |r| r.merge(title: titles[r[:session_id]]) }
  end
end
