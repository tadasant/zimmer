# frozen_string_literal: true

# The Costs page: what Zimmer's inference actually costs, from stored volumes
# priced at current list rates.
#
# Sits alongside Quotas deliberately. Quotas answers "how much headroom is left
# in the window" from Anthropic's rate-limit headers; Costs answers "what did we
# spend it on" from our own ledger. They are different questions with different
# sources, and neither substitutes for the other.
class CostsController < ApplicationController
  # Bounded so a hand-typed `?days=100000` cannot ask Postgres to scan the whole
  # table and time out the page.
  MAX_DAYS = 365
  DEFAULT_DAYS = 7

  def show
    @days = requested_days
    @analytics = CostAnalytics.new(from: @days.days.ago)

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
    @top_sessions = snapshot[:top_sessions]
    @unpriced_models = snapshot[:unpriced_models]

    @last_ingested_at = [
      SessionTokenUsage.maximum(:called_at),
      AdhocTokenUsage.maximum(:called_at)
    ].compact.max
  end

  private

  def requested_days
    value = params[:days].to_i
    return DEFAULT_DAYS unless value.positive?
    value.clamp(1, MAX_DAYS)
  end
end
