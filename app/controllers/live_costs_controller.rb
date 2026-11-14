# frozen_string_literal: true

# /live/costs — what each Live voice engine has cost, by engine, conversation,
# day and operation, with the speed and failure signals beside the money
# (LiveConversations::CostReport). `/live/costs.csv` is every ledger row in the
# window, for analysis elsewhere.
class LiveCostsController < ApplicationController
  def show
    @report = begin
      LiveConversations::CostReport.new(days: params[:days], engine: params[:engine])
    rescue ArgumentError => e
      return redirect_to live_costs_path, alert: e.message
    end
    respond_to do |format|
      format.html
      format.json { render json: @report.as_api_json }
      format.csv do
        send_data @report.to_csv, type: "text/csv", filename: "live-usage-#{@report.from.to_date}-#{@report.to.to_date}.csv"
      end
    end
  end
end
