# frozen_string_literal: true

# The Costs page: what Zimmer's inference actually costs, from stored volumes
# priced at current list rates.
#
# Sits alongside Quotas deliberately. Quotas answers "how much headroom is left
# in the window" from Anthropic's rate-limit headers; Costs answers "what did we
# spend it on" from our own ledger. They are different questions with different
# sources, and neither substitutes for the other.
class CostsController < ApplicationController
  def show
    # One object carries the window whether it came from a one-click preset or the
    # calendar, so every link on the page can round-trip it with `to_params`.
    @window = CostWindow.from_params(params)
    @analytics = @window.analytics

    # One cached bundle rather than a dozen separate scans of the same window —
    # see CostAnalytics#snapshot for why that matters at a year of history.
    snapshot = @analytics.snapshot
    @totals = snapshot[:totals]
    @cost_breakdown = snapshot[:cost_breakdown]
    @by_day = snapshot[:by_day]
    @by_agent_root = snapshot[:by_agent_root]
    @by_model = snapshot[:by_model]
    @by_thread_kind = snapshot[:by_thread_kind]
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
    redirect_to costs_path(CostWindow.from_params(params).to_params),
      notice: "History sweep #{run.status} — progress appears here as it runs."
  end
end
