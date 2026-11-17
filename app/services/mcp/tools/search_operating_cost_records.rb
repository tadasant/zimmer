# frozen_string_literal: true

module Mcp
  module Tools
    # Row-level export of the operating-cost tables (OperatingCosts::Records).
    class SearchOperatingCostRecords < Tool
      tool_name "search_operating_cost_records"

      description <<~DESC
        Export the rows behind the Costs page, one table at a time, newest first, paginated (`page`, `per_page` default #{OperatingCosts::Records::PER_PAGE}, max #{OperatingCosts::Records::MAX_PER_PAGE}).

        `kind`: "observations" (raw money facts: daily_cost, period_to_date, invoice), "credit_snapshots", "subscriptions", "daily_entries" (the rebuilt daily series, after each account's zimmer_share), "allocations" (each account-month split by agent root and functionality, with the method and its basis), "accounts", "vendors", "functionalities", or "runs" (collection runs). `account` (an account key) narrows the per-account kinds; `from` / `to` (YYYY-MM-DD) narrow the dated ones. For rollups use `get_operating_costs`.
      DESC

      input_schema({
        type: "object",
        properties: {
          kind: { type: "string", enum: OperatingCosts::Records::KINDS.keys, description: "Default observations." },
          account: { type: "string", description: "An account key." },
          from: { type: "string", description: "YYYY-MM-DD." },
          to: { type: "string", description: "YYYY-MM-DD." },
          page: { type: "integer", minimum: 1 },
          per_page: { type: "integer", minimum: 1, maximum: OperatingCosts::Records::MAX_PER_PAGE }
        }
      })

      def call(args)
        OperatingCosts::Records.search(kind: args["kind"] || "observations", account: args["account"], from: args["from"],
                                       to: args["to"], page: args["page"], per_page: args["per_page"])
      rescue ArgumentError => e
        raise ToolError, e.message
      end
    end
  end
end
