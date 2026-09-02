# frozen_string_literal: true

module Mcp
  module Tools
    # The read half of the gate decision ledger, and the reason the ledger moved
    # into a database at all.
    #
    # The gates used to calibrate by reading a whole JSON file — 3.4 MB and 300
    # entries for the zimmer PR ledger, to find the handful of comparable
    # decisions that actually inform the rating in hand. This is that read,
    # filtered, and its description is as much of the feature as its code: a gate
    # that does not know it can ask for "the last 10 holds on this surface" will
    # go on paging through everything.
    class SearchGateDecisions < Tool
      # Full entries are long-form prose — 11.5 KB on average — so a list is
      # summaries and `include_payload` is opt-in on a narrow result set.
      SUMMARY_REASON_LENGTH = 400

      tool_name "search_gate_decisions"

      description <<~DESC
        Search the gate decision ledger: every rating `pr-merge-gate` and `issue-work-gate` has made, with the reasoning behind it.

        **This replaces reading a ledger file.** The corpus is ~1,500 decisions and ~13 MB of prose. Ask it a question instead of reading it: filters compose, and the answer comes back newest-first.

        **The calibration query — start here.** Before rating anything, read how this gate has rated this surface recently:

        - `{ gate: "pr_merge", surface: "zimmer", limit: 10 }` — the last 10 PR-merge decisions on zimmer
        - `{ gate: "issue_work", surface: "strad", decision: "hold", limit: 10 }` — the last 10 issues this gate held on strad, which is what calibrates a hold
        - `{ gate: "pr_merge", surface: "zimmer", with_human_feedback: true }` — **the highest-signal read in the ledger.** Every decision a human later commented on, which is the only place the gate learns it was wrong. There are few of these; read all of them.

        **Other shapes:**
        - `{ artifact_url: "https://github.com/tadasant/zimmer/pull/749" }` — has this PR been rated before? A re-rate should know what the first rating said.
        - `{ query: "air_prepare_service.rb" }` — full-text over the whole entry: the reasoning, the ratings, the justifications, the verification notes. Case-insensitive substring, so file paths, issue numbers (`#722`) and phrases all work.
        - `{ gate: "pr_merge", from: "2026-08-01", to: "2026-08-31" }` — a date window over `decided_at`.

        **Two gates, two shapes.** `pr_merge` rates a pull request (`pr`, `problem`, `solution`, `ratings`, `decision`, `reason`, …); `issue_work` rates an issue (`issue`, `posture`, `kind`, `scope_direction`, `facets`, `staleness_check`, `ratings`, `decision`, …). The schemas are heterogeneous and still moving, so only the stable fields are columns you can filter on — everything else the gate wrote is in `payload`, returned verbatim by `include_payload: true`.

        **Decision vocabulary as it stands in the corpus:** `pr_merge` → `auto-merge`, `hold`, `authorized-merge`, `merge`, `correction`. `issue_work` → `hold`, `auto-proceed`, `authorized-proceed`. Matched exactly, so a decision value that is not in the ledger returns nothing rather than an approximation.

        **Returns:** one summary per match — gate, surface, artifact, date, decision, the opening of the reason, and whether a human ever commented — plus the full entry when `include_payload` is set. Rows are append-only: a correction is a NEW decision on the same artifact, never an edit, so a search on an artifact can legitimately return several rows and the newest is the current reading.
      DESC

      input_schema({
        type: "object",
        properties: {
          gate: {
            type: "string",
            enum: GateDecision::GATES,
            description: 'Which gate made the decision. "pr_merge" rates pull requests, "issue_work" rates issues.'
          },
          surface: {
            type: "string",
            description: 'The agent root / repo the gate rated on — "zimmer", "strad", "strad_production", "artifacts", "tadasant_internal", "motet", "obs", … Case and hyphens are normalized.'
          },
          decision: {
            type: "string",
            description: 'The verdict, matched exactly. pr_merge: "auto-merge", "hold", "authorized-merge". issue_work: "hold", "auto-proceed", "authorized-proceed".'
          },
          artifact_url: {
            type: "string",
            description: "The exact PR or issue URL this decision was about. Use it to find every rating ever made on one artifact."
          },
          query: {
            type: "string",
            description: "Full-text search over the whole entry — reason, ratings, justifications, verification notes, everything the gate wrote. Case-insensitive substring, so file paths and issue numbers match literally."
          },
          with_human_feedback: {
            type: "boolean",
            description: "Only decisions a human later commented on. Rare and high-signal: this is where the gate finds out it got one wrong. Default: false."
          },
          from: {
            type: "string",
            description: "Earliest decision date, ISO (2026-08-01). Inclusive."
          },
          to: {
            type: "string",
            description: "Latest decision date, ISO (2026-08-31). Inclusive."
          },
          limit: {
            type: "number",
            minimum: 1,
            maximum: GateDecisions::Filters::MAX_LIMIT,
            description: "How many decisions to return, newest first. Default #{GateDecisions::Filters::DEFAULT_LIMIT}, max #{GateDecisions::Filters::MAX_LIMIT}."
          },
          offset: {
            type: "number",
            minimum: 0,
            description: "Skip this many matches before returning. Page further back through a filter without widening it."
          },
          include_payload: {
            type: "boolean",
            description: "Return each decision's full entry verbatim, not just the summary. Entries average 11.5 KB of prose — use it with a small `limit` on a narrow filter, not to dump the ledger."
          }
        },
        required: []
      })

      def call(args)
        filters = GateDecisions::Filters.new(args)
        scope = filters.scope.includes(:feedbacks)
        total = scope.count
        decisions = scope.offset(filters.offset).limit(filters.limit).to_a

        if decisions.empty?
          return "No gate decisions match #{filters.describe}.\n\nThe ledger holds #{GateDecision.count} " \
                 "decision(s) in total. Widen the filter — `decision` and `artifact_url` match exactly."
        end

        include_payload = truthy?(args["include_payload"])
        lines = [
          "## Gate decisions",
          "",
          "#{total} match(es) for #{filters.describe}; showing #{decisions.size}" \
          "#{filters.offset.positive? ? " from offset #{filters.offset}" : ""}, newest first.",
          ""
        ]

        decisions.each do |decision|
          lines << format_decision(decision, include_payload: include_payload)
          lines << ""
        end

        shown = filters.offset + decisions.size
        if total > shown
          lines << "---"
          lines << "*#{total - shown} older match(es) not shown. Use offset=#{shown} to continue.*"
        end

        lines.join("\n").strip
      rescue GateDecisions::Filters::InvalidFilter => e
        raise ToolError, e.message
      end

      private

      def format_decision(decision, include_payload:)
        lines = [
          "### #{decision.title || decision.artifact_url || "decision ##{decision.id}"}",
          "",
          "- **Id:** #{decision.id}",
          "- **Gate / surface:** #{decision.gate} / #{decision.surface}",
          "- **Decision:** #{decision.decision || '(none recorded)'}",
          "- **Decided:** #{decision.decided_at&.iso8601 || '(no date in the entry)'}"
        ]
        lines << "- **Artifact:** #{decision.artifact_url}" if decision.artifact_url.present?
        lines << "- **Producing session:** #{decision.producing_session_url}" if decision.producing_session_url.present?
        lines << "- **Recorded via:** #{decision.recorded_via}"

        reason = decision.payload["reason"]
        lines << "- **Reason:** #{truncate(reason)}" if reason.is_a?(String) && reason.present?

        feedbacks = decision.feedbacks.to_a
        if feedbacks.any?
          lines << "- **Human feedback (#{feedbacks.size}):**"
          feedbacks.each do |feedback|
            lines << "  - #{feedback.received_at&.iso8601 || 'undated'} — **#{feedback.verdict}** " \
                     "(#{feedback.display_name || 'author not recorded'}): #{truncate(feedback.note)}"
          end
        end

        if include_payload
          lines << ""
          lines << "```json"
          lines << JSON.pretty_generate(decision.payload)
          lines << "```"
        end

        lines.join("\n")
      end

      def truncate(value)
        text = value.to_s.strip
        return "(none)" if text.empty?

        text.length <= SUMMARY_REASON_LENGTH ? text : "#{text[0, SUMMARY_REASON_LENGTH]}…"
      end

      def truthy?(value)
        ActiveModel::Type::Boolean.new.cast(value) == true
      end
    end
  end
end
