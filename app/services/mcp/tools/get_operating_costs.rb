# frozen_string_literal: true

module Mcp
  module Tools
    # The read of the Costs page (/costs): what operating this deployment costs
    # in real money (OperatingCosts::Report). Not `get_costs`, which is
    # list-price token spend from Zimmer's own ledger.
    class GetOperatingCosts < Tool
      tool_name "get_operating_costs"

      description <<~DESC
        Read the all-in cost of operating this Zimmer deployment in real money: bills, subscriptions, credits and Zimmer's own metered spend, as shown on the Costs page. This is NOT `get_costs` — that one is list-price token volumes from Zimmer's ledger, which are not a bill.

        Figures run through yesterday. Returns JSON for one month (`month`, default the current one):
        - `view: "summary"` (default): totals (month to date, month projected, previous month, forward monthly run rate and its 7-day trend, share of last month from real bills) and one row per group with the accounts behind it. Accounts paid by someone else (`paid_by` other than self, e.g. CI another organisation pays for) are listed separately under `paid_by_others` and are not in the totals unless `include_external` is true.
        - `view: "timeseries"`: per-period totals by group, `granularity` "month" (default) or "day", over `from`..`to`.
        - `view: "projections"`: the monthly strip (six closed months, this month, three months ahead including promotional-credit run-out), credit balances with burn per day and run-out date, active subscriptions and upcoming renewals.
        - `view: "sources"`: per account, how its figures arrive, the last figure's date and confidence; the latest collection run per collector.
        `group_by`: "functionality" (default — the capability the cost serves; null functionality means unattributed/shared), "vendor", "account" or "agent_root" (split by each account's allocation rule). Filters `functionality` (a key, or "unattributed"), `vendor` (a key) and `agent_root` narrow every figure. Every response carries `stale` and `stale_reasons`. Row exports are `search_operating_cost_records`; writes are `action_operating_costs`.
      DESC

      input_schema({
        type: "object",
        properties: {
          view: { type: "string", enum: OperatingCosts::Report::VIEWS, description: "Default summary." },
          group_by: { type: "string", enum: OperatingCosts::Report::GROUP_BYS, description: "Default functionality." },
          granularity: { type: "string", enum: OperatingCosts::Report::GRANULARITIES, description: "timeseries only. Default month." },
          month: { type: "string", description: "YYYY-MM. Default the current month." },
          from: { type: "string", description: "timeseries only. YYYY-MM-DD." },
          to: { type: "string", description: "timeseries only. YYYY-MM-DD; default yesterday." },
          functionality: { type: "string", description: "A functionality key, or \"unattributed\"." },
          vendor: { type: "string", description: "A vendor key." },
          agent_root: { type: "string", description: "An agent root name." },
          include_external: { type: "boolean", description: "Count accounts someone else pays for in the totals. Default false." }
        }
      })

      def call(args)
        report = OperatingCosts::Report.new(
          month: args["month"], functionality: args["functionality"], vendor: args["vendor"],
          agent_root: args["agent_root"], include_external: args["include_external"]
        )
        report.as_api_json(view: args["view"] || "summary", group_by: args["group_by"] || "functionality",
                           granularity: args["granularity"] || "month", from: args["from"], to: args["to"])
          .merge(page: "#{context.base_url.to_s.chomp('/')}/costs")
      rescue ArgumentError, Date::Error => e
        raise ToolError, e.message
      end
    end
  end
end
