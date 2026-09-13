# frozen_string_literal: true

# GET /api/v1/goal_checks — how the goal check read on the sessions that came to
# rest in a window. The REST half of get_outcome_analysis's `goal_checks` view and
# of /outcomes/goal_checks; all three render GoalCheckTally, so they cannot disagree.
#
# Query parameters (all optional, the Outcomes filters): from, to (YYYY-MM-DD, on the
# session's created_at; the last 7 days when both are absent), agent_root,
# agent_runtime, model.
class Api::V1::GoalChecksController < Api::BaseController
  def index
    filters = OutcomeAnalyses::LedgerFilters.from_params(params)
    tally = GoalCheckTally.new(filters: filters)

    render json: { filters: filters.to_h.slice("from", "to", "agent_root", "agent_runtime", "model") }.merge(tally.to_h)
  end
end
