# frozen_string_literal: true

# The Live voice-engine cost ledger over the REST API (LiveConversations::CostReport).
#
#   GET /api/v1/live/costs?days=7&engine=gpt_live_claude          the rollup: by engine, operation, day, conversation; caps
#   GET /api/v1/live/usage_events?days=7&engine=…&limit=1000      the ledger rows themselves, oldest first, for export
#
# Read-only, on an API key or the app's sign-in.
class Api::V1::LiveCostsController < Api::BaseController
  accepts_native_app_tokens

  EVENTS_LIMIT = 1_000

  def show
    render json: report.as_api_json
  rescue ArgumentError => e
    render_api_error("Bad Request", e.message, status: :bad_request)
  end

  def events
    limit = params[:limit].present? ? params[:limit].to_i.clamp(1, LiveConversations::CostReport::EXPORT_LIMIT) : EVENTS_LIMIT
    rows = report.events(limit: limit)
    render json: { window: { from: report.from.iso8601, to: report.to.iso8601, engine: report.engine }, events: rows.map(&:as_api_json) }
  rescue ArgumentError => e
    render_api_error("Bad Request", e.message, status: :bad_request)
  end

  private

  def report = @report ||= LiveConversations::CostReport.new(days: params[:days], engine: params[:engine])
end
