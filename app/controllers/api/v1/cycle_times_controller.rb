# frozen_string_literal: true

# GET /api/v1/cycle_times — where autonomous tasks' wall-clock went over a window.
# GET /api/v1/cycle_times/:id — one hierarchy's breakdown; :id is its ROOT session id.
#
# The REST half of `get_cycle_time` and of /cycle_times. All three read
# CycleTimes::Report over the persisted cycle_time_analyses rows, so they cannot
# disagree, and none of them parses a transcript.
#
# Query parameters (index, all optional): days (1–365, default 7) or from/to
# (YYYY-MM-DD, inclusive, on the day the hierarchy FINISHED), agent_root, limit
# (rows listed, default 20, max 200).
# Query parameters (show): include_segments=true for every lane's segments.
class Api::V1::CycleTimesController < Api::BaseController
  # Zimmer's iOS app: /cycle_times is a page any signed-in person reads.
  accepts_native_app_tokens

  def index
    window = CostWindow.from_params(days: params[:days], from: params[:from], to: params[:to])
    report = CycleTimes::Report.new(window: window, agent_root: params[:agent_root])
    limit = params[:limit].to_i.positive? ? [ params[:limit].to_i, 200 ].min : 20

    render json: report.to_h(rows_limit: limit)
  end

  def show
    analysis = CycleTimeAnalysis.find_by(root_session_id: params[:id])
    if analysis.nil?
      render_api_error("Not found", "No cycle time row for root session #{params[:id]} — it is in flight, not a root, " \
                                     "or not yet analyzed", status: :not_found)
      return
    end

    render json: CycleTimes::Detail.new(analysis).to_h(include_segments: ActiveModel::Type::Boolean.new.cast(params[:include_segments]))
  end
end
