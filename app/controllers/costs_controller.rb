# frozen_string_literal: true

# The Costs page: what Zimmer's inference actually costs, from stored volumes
# priced at current list rates.
#
# Sits alongside Inference deliberately. Inference answers "how much headroom is left
# in the window" from Anthropic's rate-limit headers; Costs answers "what did we
# spend it on" from our own ledger. They are different questions with different
# sources, and neither substitutes for the other.
class CostsController < ApplicationController
  def show
    # One object carries the window whether it came from a one-click preset or the
    # calendar, so every link on the page can round-trip it with `to_params`.
    @window = CostWindow.from_params(params)

    # The drilldown. `agent_root` and `session_id` are the same two arguments
    # `get_costs` takes and `GET /api/v1/costs/records` filters by; without them
    # here, a reader who spots one root at a large share on this page has to
    # leave for the REST API to ask what that root actually spent it on.
    @scope = CostScope.from_params(params)
    @scoped_session = Session.find_by(id: @scope.session_id) if @scope.session?
    @analytics = @window.analytics(scope: @scope)

    # One cached bundle rather than a dozen separate scans of the same window —
    # see CostAnalytics#snapshot for why that matters at a year of history.
    snapshot = @analytics.snapshot
    @totals = snapshot[:totals]
    @cost_breakdown = snapshot[:cost_breakdown]
    @by_day = snapshot[:by_day]
    @by_agent_root = snapshot[:by_agent_root]
    @by_model = snapshot[:by_model]
    @by_thread_kind = snapshot[:by_thread_kind]
    @by_runtime = snapshot[:by_runtime]
    @by_adhoc_source = snapshot[:by_adhoc_source]
    @by_feature = snapshot[:by_feature]
    @by_experiment = snapshot[:by_experiment]
    @top_sessions = snapshot[:top_sessions]
    @unpriced_models = snapshot[:unpriced_models]

    # How complete the ledger is, from the same object the REST API and the MCP
    # tool read. Without it the page implies more coverage than it has: every
    # figure above is bounded by whatever has been ingested, and before the
    # historical sweep finishes that is only spend since ingestion shipped.
    @coverage = TokenUsageBackfill.coverage
    @last_ingested_at = @coverage[:covers_until]

    # The scheduler's view of the same ledger. Not part of the cached window
    # snapshot: these are current rates over a fixed per-combination sample, not
    # a rollup of the window the picker selected, and they turn over on their own
    # cron. One small indexed read.
    @burn_rates = HarnessModelBurnRate.fresh.by_rate.to_a
  end

  # POST /costs/backfill
  #
  # The re-scan button. There is no shell on the production box to run a rake
  # task from — deliberately — so asking for a fresh sweep of the whole corpus
  # has to be something the app itself offers. Idempotent twice over: it returns
  # the run already in flight rather than starting a second, and ingestion
  # upserts on `request_id`, so a sweep that re-reads a directory writes nothing.
  def backfill
    run = TokenUsageBackfill.request!(trigger: "manual")

    # The cron would pick this up within five minutes anyway; enqueuing now means
    # the button does something visible immediately.
    TokenUsageBackfillJob.perform_later

    # Back to the window the button was pressed from, preset or calendar range
    # alike — a sweep is not a reason to change what the viewer was looking at.
    # The scope rides back with the window for the same reason: a sweep is not a
    # reason to widen the page from one agent root to the whole fleet either.
    redirect_to costs_path(CostWindow.from_params(params).to_params.merge(CostScope.from_params(params).to_params)),
      notice: "History sweep #{run.status} — progress appears here as it runs."
  end
end
