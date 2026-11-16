# frozen_string_literal: true

# The Cycle Time page: tasks Zimmer completed end to end autonomously, and where
# their wall-clock went.
#
# READ-ONLY. Every number comes from cycle_time_analyses, which
# CycleTimes::Analyzer writes in a job when a hierarchy settles; nothing here
# parses a transcript. The figures come from CycleTimes::Report, the same object
# GET /api/v1/cycle_times and `get_cycle_time` read, so the three cannot
# disagree.
#
# Structured after GateDecisionsController and OutcomesController: a top-level
# page with its own routes, between them in the menu.
class CycleTimesController < ApplicationController
  PER_PAGE = 50

  def index
    @window = CostWindow.from_params(days: params[:days], from: params[:from], to: params[:to])
    @agent_root = params[:agent_root].presence
    @report = CycleTimes::Report.new(window: @window, agent_root: @agent_root)
    @page = [ params[:page].to_i, 1 ].max
    @total = @report.count
    @rows = @report.rows(limit: PER_PAGE, offset: (@page - 1) * PER_PAGE)
    @has_next_page = @total > @page * PER_PAGE
    @agent_roots = CycleTimeAnalysis.current.eligible.where.not(agent_root: nil).distinct.order(:agent_root).pluck(:agent_root)
  end

  # Keyed by the root session's id — the hierarchy's natural name — rather than
  # the analysis row's.
  def show
    @analysis = CycleTimeAnalysis.find_by!(root_session_id: params[:id])
    @window_params = params.permit(:days, :from, :to, :agent_root).to_h
  end
end
