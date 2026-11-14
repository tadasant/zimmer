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

        Returns JSON for a window: totals; per engine the spend, spend per conversation, delegations, average delegation round trip, time-to-first-audio p50/p90, errors and fallbacks; spend by operation and model with token, audio and second volumes; spend by day; the most expensive conversations; today's spend against each experimental engine's caps; and whether each engine can run. Every row was priced from the price table version it names. Change the engine, the Claude model and the caps with `action_live_settings` (the live model itself cannot change the caps).
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
