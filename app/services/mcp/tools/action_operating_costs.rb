# frozen_string_literal: true

module Mcp
  module Tools
    # Every write on operating costs (OperatingCosts::Actions) — the same action
    # set the Costs page's forms and `POST /api/v1/operating_costs/actions` use.
    class ActionOperatingCosts < Tool
      tool_name "action_operating_costs"

      description <<~DESC
        Write operating costs: the taxonomy (functionalities, vendors, accounts), subscriptions, money figures and credit balances. Zimmer never calls a vendor's billing API itself; this is how external figures arrive. Every write upserts by natural key, so repeating a call changes nothing and reports `unchanged`. After a write, each touched account's daily series is rebuilt and its months re-split.

        Actions:
        - `record`: a batch, all or nothing. `payload` is an object with any of these arrays (references are by key, so one batch can create a vendor, its accounts and their figures):
          - `functionalities`: {key, name, description?, agent_roots?: [root names it claims], mcp_servers?: [server names], position?, active?}
          - `vendors`: {key, name, category: #{OperatingCostVendor::CATEGORIES.join('|')}, pricing_model: #{OperatingCostVendor::PRICING_MODELS.join('|')}, ingest_method: #{OperatingCostVendor::INGEST_METHODS.join('|')}, billing_url?, notes?, active?}
          - `accounts`: {key, label, vendor: vendor key, functionality?: key or null (unattributed), paid_by?: "self" (default) or who pays it — anything else is shown but excluded from totals, zimmer_share?: 0..1 (default 1), allocation_rule?: #{OperatingCostAccount::ALLOCATION_RULES.join('|')}, allocation_config?: {agent_roots: [...]} for direct_root, {runtime: "claude_code"} for token_spend_share, {mcp_servers: [...]} for mcp_server_sessions, derived_source?: #{OperatingCostAccount::DERIVED_SOURCES.join('|')} (the daily job writes Zimmer's own estimate here), environment?, external_ref?, notes?, active?}
          - `subscriptions`: {account, plan_name, amount, currency? (default USD), amount_usd? (required when not USD), interval: month|year, quantity?, included_usage_usd?, started_on, ended_on?, renews_on?, auto_renew?, notes?} — identified by account + plan_name + started_on
          - `observations`: {account, metric: daily_cost|period_to_date|invoice, as_of_date (daily_cost, period_to_date), period_start (period_to_date, invoice), period_end (invoice), amount, currency?, amount_usd?, source: #{(OperatingCostObservation::SOURCES - [ 'derived' ]).join('|')}, confidence: #{OperatingCostObservation::CONFIDENCES.join('|')}, evidence?: where the figure came from, raw_payload?: the vendor's JSON (redacted and capped)} — identified by account + metric + as_of_date + period_start + source
          - `credit_snapshots`: {account, as_of_date, balance, currency?, balance_usd?, kind: #{OperatingCostCreditSnapshot::KINDS.join('|')}, granted_total?, expires_on?, source, evidence?} — identified by account + as_of_date + source
          `collector` (optional, e.g. "agent:daily") records the batch as a collection run, which is what the Costs page and /health read to say whether collection ran.
        - `upsert_functionality`, `upsert_vendor`, `upsert_account`, `upsert_subscription`, `upsert_observation`, `upsert_credit_snapshot`: one `item` of that shape.
        - `end_subscription`: `account`, `plan_name`, `ended_on`, optional `started_on`.
        - `delete_observation`, `delete_credit_snapshot`: `id` (from `search_operating_cost_records`).
        - `collect_now`: run the daily derived collection now.

        Amounts are decimals in the stated currency; Zimmer does no currency conversion. Dates are YYYY-MM-DD. Never put credentials in `evidence` or `notes`.
      DESC

      input_schema({
        type: "object",
        properties: {
          action: { type: "string", enum: OperatingCosts::Actions::NAMES },
          payload: { type: "object", description: "record: arrays keyed by kind." },
          collector: { type: "string", description: "record: name this batch as a collection run, e.g. \"agent:daily\"." },
          item: { type: "object", description: "upsert_*: the one item." },
          account: { type: "string", description: "end_subscription: account key." },
          plan_name: { type: "string", description: "end_subscription." },
          started_on: { type: "string", description: "end_subscription: which subscription, when the plan was taken more than once." },
          ended_on: { type: "string", description: "end_subscription: YYYY-MM-DD." },
          id: { type: "integer", description: "delete_*: the row id." }
        },
        required: [ "action" ]
      })

      def call(args)
        OperatingCosts::Actions.perform(args["action"], args.except("action"), source: "mcp:action_operating_costs",
                                        session_id: context.self_session_id)
      rescue OperatingCosts::Actions::Error => e
        raise ToolError, e.message
      end
    end
  end
end
