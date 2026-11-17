# frozen_string_literal: true

# Operating costs over the REST API — the Costs page's figures and its writes.
#
#   GET  /api/v1/operating_costs?view=summary&group_by=functionality&month=YYYY-MM
#   GET  /api/v1/operating_costs/records?kind=observations&account=…&page=1
#   POST /api/v1/operating_costs/actions  { "action": "record", "payload": {…} }
#
# Mirrors the `operating_costs` MCP tool group one to one (get_operating_costs,
# search_operating_cost_records, action_operating_costs): all three read
# OperatingCosts::Report / Records and write through OperatingCosts::Actions.
#
# Not to be confused with `/api/v1/costs`, the token-spend ledger, which keeps
# that path because installed iOS builds call it.
class Api::V1::OperatingCostsController < Api::BaseController
  CHANGE_SOURCE = "api:/api/v1/operating_costs/actions"

  def show
    report = OperatingCosts::Report.new(
      month: params[:month], functionality: params[:functionality], vendor: params[:vendor],
      agent_root: params[:agent_root], include_external: params[:include_external]
    )
    render json: report.as_api_json(view: params[:view].presence || "summary", group_by: params[:group_by].presence || "functionality",
                                    granularity: params[:granularity].presence || "month", from: params[:from].presence,
                                    to: params[:to].presence)
  rescue ArgumentError, Date::Error => e
    render_api_error("Bad Request", e.message, status: :bad_request)
  end

  def records
    render json: OperatingCosts::Records.search(kind: params[:kind].presence || "observations", account: params[:account],
                                                from: params[:from], to: params[:to], page: params[:page],
                                                per_page: params[:per_page])
  rescue ArgumentError => e
    render_api_error("Bad Request", e.message, status: :bad_request)
  end

  # The body's `action` names the OperatingCosts::Actions action. Rails keeps its
  # own `action` in `params`, so the body is read from request_parameters.
  def perform
    body = request.request_parameters
    render json: OperatingCosts::Actions.perform(body["action"], body.except("action", "session_id"),
                                                 source: CHANGE_SOURCE, session_id: body["session_id"].presence&.to_i)
  rescue OperatingCosts::Actions::Error => e
    render_api_error("Unprocessable Entity", e.message, status: :unprocessable_entity)
  end
end
