# frozen_string_literal: true

# The Costs page: the all-in cost of operating this deployment in real money,
# by functionality, vendor and agent root, with projections. Its read model is
# OperatingCosts::Report and every write goes through OperatingCosts::Actions —
# the same two objects `GET/POST /api/v1/operating_costs*` and the
# `operating_costs` MCP tool group use, so the three never disagree.
#
# Token Spend is the other cost page: list-price token volumes from Zimmer's own
# ledger. Those dollars are not a bill (Claude Code and Codex run on
# subscriptions), so they are never summed in here.
class OperatingCostsController < ApplicationController
  CHANGE_SOURCE = "web:/costs"

  # Every field any Manage form sends inside `item`, across all six upserts.
  # OperatingCosts::Recorder decides which apply to which kind.
  ITEM_FIELDS = %w[
    key name description agent_roots mcp_servers position active
    category pricing_model ingest_method billing_url notes
    label vendor functionality paid_by zimmer_share allocation_rule allocation_config derived_source environment external_ref
    account plan_name amount currency amount_usd interval quantity included_usage_usd started_on ended_on renews_on auto_renew
    metric as_of_date period_start period_end source confidence evidence
    balance balance_usd kind granted_total expires_on
  ].freeze

  def show
    @report = begin
      OperatingCosts::Report.new(**report_params)
    rescue ArgumentError => e
      flash.now[:alert] = e.message
      OperatingCosts::Report.new
    end
    @functionalities = OperatingCostFunctionality.ordered.to_a
    @vendors = OperatingCostVendor.ordered.to_a
    @accounts = OperatingCostAccount.includes(:vendor).ordered.to_a
    @recent_observations = OperatingCostObservation.includes(:account).order(updated_at: :desc).limit(10).to_a
    @recent_snapshots = OperatingCostCreditSnapshot.includes(:account).order(updated_at: :desc).limit(5).to_a
  end

  # POST /costs/actions — every form on the page. `operation` names an
  # OperatingCosts::Actions action; `item` carries an upsert's fields.
  def perform
    receipt = OperatingCosts::Actions.perform(params.require(:operation), action_args, source: CHANGE_SOURCE)
    redirect_to operating_costs_path(return_params), notice: notice_for(receipt)
  rescue OperatingCosts::Actions::Error, ActionController::ParameterMissing => e
    redirect_to operating_costs_path(return_params), alert: e.message
  end

  private

  def report_params
    params.permit(:month, :functionality, :vendor, :agent_root, :include_external)
      .to_h.symbolize_keys.slice(:month, :functionality, :vendor, :agent_root, :include_external)
  end

  def return_params
    params.fetch(:return_to, {}).permit(:month, :functionality, :vendor, :agent_root, :include_external).to_h
  end

  # Form fields arrive as strings; lists arrive one per line or comma-separated,
  # and allocation_config as JSON, so the receipt is the same as MCP's.
  def action_args
    args = params.permit(:account, :plan_name, :ended_on, :started_on, :id).to_h
    item = params.fetch(:item, {}).permit(*ITEM_FIELDS).to_h
    if item.any?
      # A blank field or "(unchanged)" means "leave it as it is". Where empty is
      # a value, the form sends a word for it: no functionality, no derived
      # source, and "none" in a list box clears the list.
      item.reject! { |_key, value| value.to_s.strip == "" }
      item["functionality"] = "" if item["functionality"] == "unattributed"
      item["derived_source"] = "" if item["derived_source"] == "none"
      %w[agent_roots mcp_servers].each do |key|
        next unless item.key?(key)

        item[key] = item[key].strip.casecmp?("none") ? [] : item[key].split(/[\n,]/).map(&:strip).reject(&:blank?)
      end
      if item.key?("allocation_config")
        item["allocation_config"] = parse_json_object(item["allocation_config"])
      end
      %w[active auto_renew].each { |key| item[key] = item[key] == "1" if item.key?(key) }
      args["item"] = item
    end
    args
  end

  def parse_json_object(text)
    return {} if text.blank?

    parsed = JSON.parse(text)
    raise OperatingCosts::Actions::Error, "allocation_config must be a JSON object" unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError
    raise OperatingCosts::Actions::Error, "allocation_config is not valid JSON"
  end

  def notice_for(receipt)
    case receipt[:action]
    when "collect_now" then "Collection queued — it runs within a minute."
    when "end_subscription" then "Subscription ended."
    when "delete_observation", "delete_credit_snapshot" then "Deleted."
    else
      counts = receipt[:counts].to_h.values.each_with_object(Hash.new(0)) { |c, sum| c.each { |k, v| sum[k] += v } }
      "Saved: #{counts['created']} created, #{counts['updated']} updated, #{counts['unchanged']} unchanged."
    end
  end
end
