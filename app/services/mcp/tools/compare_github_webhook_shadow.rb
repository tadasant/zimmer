# frozen_string_literal: true

module Mcp
  module Tools
    # The GitHub webhook's shadow comparison (Webhooks::GithubShadowComparison) over a window the
    # caller picks. /health and get_system_health carry the last 24 hours; this is the same reading
    # with a chosen window, one condition at a time if wanted, and the events behind the counts.
    class CompareGithubWebhookShadow < Tool
      tool_name "compare_github_webhook_shadow"

      description <<~DESC
        Compare what GitHub's webhook WOULD have fired against what the GitHub trigger poller DID
        fire, while `GITHUB_TRIGGER_INGEST_MODE=webhook_shadow`. In that mode the webhook verifies and
        records every delivery and matches it against every GitHub trigger condition, but fires and
        claims nothing; the poller fires exactly as on `poll`. Both record what they saw, and this
        pairs them per condition and event:

        - `matched`: both paths saw it. `webhook_lead_seconds` is how far ahead the webhook was
          (negative: the poller was ahead).
        - `webhook_only`: the webhook would have fired it and the poller never did — in
          `webhook_with_poll_fallback` that would be a session the poller would not have spawned.
        - `poll_only`: the poller fired it and no delivery matched — a dropped delivery, a hook
          missing an event type, or a delivery that arrived after the poll.
        - `pending`: one path has seen it and it is younger than `grace_minutes`.

        Returns the mode, totals, latency (median / p90 / max webhook lead), a row per condition, and
        the newest events (`limit`). Rows are only written in `webhook_shadow` and kept 30 days, so
        outside that mode, or further back, there is nothing to compare. Read-only.
      DESC

      input_schema({
        type: "object",
        properties: {
          since: { type: "string", description: "ISO 8601 time to compare from. Default: 24 hours ago. At most 30 days back." },
          grace_minutes: { type: "integer", description: "How long one path's observation may wait for the other's before it counts as a miss. Default: two poll intervals plus five minutes, at least 15." },
          condition_id: { type: "integer", description: "Only this trigger condition." },
          limit: { type: "integer", description: "How many of the newest events to list in `recent`. Default 30, at most 200." }
        }
      })

      def call(args)
        report = Webhooks::GithubShadowComparison.report(
          since: parse_since(args["since"]),
          grace: args["grace_minutes"].presence && args["grace_minutes"].to_i.clamp(0, 24 * 60).minutes,
          condition_id: args["condition_id"].presence&.to_i,
          conditions: visible_conditions,
          recent: (args["limit"].presence || Webhooks::GithubShadowComparison::DEFAULT_RECENT).to_i
        )
        report.merge(since: report[:since].iso8601)
      end

      private

      # A restricted connection sees only conditions on the roots it may act on, as search_triggers
      # shows it only those triggers.
      def visible_conditions
        return nil unless context.restricted?

        TriggerCondition.github.joins(:trigger).where(triggers: { agent_root_name: context.allowed_agent_roots })
      end

      def parse_since(value)
        return nil if value.blank?

        Time.iso8601(value.to_s).clamp(TriggerShadowObservation::RETENTION.ago, Time.current)
      rescue ArgumentError
        raise ToolError, "since must be an ISO 8601 time, e.g. 2026-11-16T15:00:00Z"
      end
    end
  end
end
