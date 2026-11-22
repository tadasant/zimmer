# frozen_string_literal: true

module Mcp
  module Tools
    # The per-session PR pollers' webhook shadow (Github::PrWebhookShadowReport) over a window the
    # caller picks. The PR-tracking sibling of compare_github_webhook_shadow, which covers triggers.
    class CompareGithubPrWebhookShadow < Tool
      tool_name "compare_github_pr_webhook_shadow"

      description <<~DESC
        Report whether GitHub's webhook announced the pull-request changes the per-session PR
        pollers found, while `GITHUB_PR_INGEST_MODE` is `webhook_shadow` or
        `webhook_with_poll_fallback`. The trigger-side equivalent is `compare_github_webhook_shadow`.

        Every time a poll of a webhook-covered session finds a change, Zimmer records whether a
        webhook signal for it arrived first. Per kind — `status` (PR open/merged/closed), `ci` (the
        recorded CI status), `comments` (a new comment), `merge_conflict` (a conflict appeared or
        cleared):

        - `hit`: the webhook signalled the change before the poll found it. `lead` is how many
          seconds ahead it was (median / p90 / max). The signal store keeps only the newest signal
          per PR and kind, so after a burst of deliveries the lead is a lower bound.
        - `miss`: the poll found the change and no signal had announced it — a hook missing an
          event type, a dropped delivery, or a change no delivery names. In
          `webhook_with_poll_fallback` every miss is a change only the 10-minute fallback caught.

        Returns the current mode, totals, overall lead, a row per kind, the count per mode the
        rows were written in, and the newest misses (`limit`). Nothing is recorded in `poll`, for a
        PR's first reading, or for a session whose repositories have not delivered within six
        hours. Rows are kept 30 days. Read-only.
      DESC

      input_schema({
        type: "object",
        properties: {
          since: { type: "string", description: "ISO 8601 time to report from. Default: 24 hours ago. At most 30 days back." },
          kind: { type: "string", enum: GithubPrShadowObservation::KINDS, description: "Only this kind of change." },
          mode: { type: "string", enum: %w[webhook_shadow webhook_with_poll_fallback], description: "Only rows written in this ingest mode." },
          limit: { type: "integer", description: "How many of the newest misses to list in `recent_misses`. Default 30, at most 200." }
        }
      })

      def call(args)
        kind = args["kind"].presence
        raise ToolError, "kind must be one of #{GithubPrShadowObservation::KINDS.join(', ')}" if kind && GithubPrShadowObservation::KINDS.exclude?(kind)

        report = Github::PrWebhookShadowReport.report(
          since: parse_since(args["since"]),
          kind: kind,
          mode: args["mode"].presence,
          visible: visible_sessions,
          recent: (args["limit"].presence || Github::PrWebhookShadowReport::DEFAULT_RECENT).to_i
        )
        report.merge(since: report[:since].iso8601)
      end

      private

      # A restricted connection sees only sessions on the roots it may act on, compared as
      # canonical root tokens (Tool#allowed_root?), so an alias of an allowed root still counts.
      def visible_sessions
        return nil unless context.restricted?

        lambda do |session_ids|
          Session.where(id: session_ids).pluck(:id, Arel.sql("metadata->>'agent_root_key'"))
            .filter_map { |id, root| id if allowed_root?(root) }
        end
      end

      def parse_since(value)
        return nil if value.blank?

        Time.iso8601(value.to_s).clamp(GithubPrShadowObservation::RETENTION.ago, Time.current)
      rescue ArgumentError
        raise ToolError, "since must be an ISO 8601 time, e.g. 2026-11-16T15:00:00Z"
      end
    end
  end
end
