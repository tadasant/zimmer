# frozen_string_literal: true

module Mcp
  module Tools
    # The read of /live/costs: what each Live voice engine has cost and how it
    # performed (LiveConversations::CostReport), for deciding which engine to
    # keep. Read-only; the caps that bound it are Live settings.
    class GetLiveCosts < Tool
      tool_name "get_live_costs"

      description <<~DESC
        Read what Live Mode's voice engines have cost, from the voice-engine ledger: OpenAI Realtime (the default), GPT-Live with Claude reasoning, and the LiveKit cascade.

        Returns JSON for a window: totals; per mode (an engine with the models it ran on, e.g. `gpt-realtime-2.1 · effort high` or `gpt-live-1 + claude-sonnet-5-5`) the billed and list cost, cost per conversation and per call-minute, call minutes, time-to-first-audio p50/p90, delegations and their average round trip, errors and fallbacks; spend by operation and model with token, audio and second volumes; spend by day; the most expensive conversations; today's spend against each experimental engine's caps; and whether each engine can run. Money is `billed_usd` (metered) beside `list_usd` (list price, which is what Claude-on-subscription tokens would have cost). Every row was priced from the price table version it names. Change the engine, the Claude model and the caps with `action_live_settings` (the live model itself cannot change the caps).
      DESC

      input_schema({
        type: "object",
        properties: {
          days: { type: "integer", minimum: 1, maximum: LiveConversations::CostReport::MAX_DAYS, description: "Window, in days back from now. Default #{LiveConversations::CostReport::DEFAULT_DAYS}." },
          engine: { type: "string", enum: LiveUsageEvent::ENGINES, description: "Only this engine." }
        }
      })

      def call(args)
        report = LiveConversations::CostReport.new(days: args["days"], engine: args["engine"])
        JSON.pretty_generate(report.as_api_json.merge(page: "#{context.base_url}/live/costs", rows: "#{context.base_url}/api/v1/live/usage_events"))
      rescue ArgumentError => e
        raise ToolError, e.message
      end
    end
  end
end
