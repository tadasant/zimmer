# frozen_string_literal: true

module Mcp
  module Tools
    # The write half of the gate decision ledger: a gate recording the rating it
    # just made.
    #
    # THIS TOOL IS IN ITS OWN GROUP, AND THAT IS DELIBERATE.
    #
    # `gate_decisions` is an OPT-IN group of its own rather than a few more tools
    # in `sessions`, because otherwise every session carrying `zimmer-sessions` —
    # which is most of them — would be handed the ability to write gate ratings;
    # and it is outside BASE_GROUPS so that the unscoped `/mcp` surface does not
    # carry it either. A connection has to name `gate_decisions` to get this tool;
    # one scoped to `gate_decisions_readonly` gets the two reads and not this.
    # That is a scoping boundary rather than an authorization one — see
    # Mcp::Registry for what it does and does not buy.
    #
    # TWO THINGS THIS TOOL WILL NOT LET A CALLER DO.
    #
    # It will not let a caller name its own author: `writing_session_id` is taken
    # from the MCP connection (RuntimeConfigPostProcessor stamps it onto the URL
    # in the session's own runtime config), never from an argument. A row that can
    # name its own author is a row an agent can launder a decision through.
    #
    # And it will not write `human_feedback`. That key is dropped from the entry,
    # always, on every path — it is not a payload field in this schema. Feedback
    # is GateDecisionFeedback, reachable only from the browser surface, because its
    # entire value is that a machine did not write it. That boundary is narrower
    # than "human-only" — see GateDecisionFeedback for why.
    class RecordGateDecision < Tool
      tool_name "record_gate_decision"

      description <<~DESC
        Record one gate decision — a `pr-merge-gate` verdict on a pull request, or an `issue-work-gate` verdict on an issue.

        **This replaces appending to the ledger JSON and opening a PR for it.** One call, no branch, no rebase against another gate writing at the same time.

        **The entry is yours.** Pass whatever your gate's schema says a decision is, as `entry`. It is stored verbatim and returned verbatim. A handful of stable fields (`pr`/`issue`, `decided_at`, `decision`, `producing_session`/`spawned_session`) are also promoted to indexed columns so `search_gate_decisions` can filter on them — but nothing is dropped, nothing is renamed, and a key your gate adds next week needs no change here.

        **`human_feedback` is not writable from this tool, or any other, ever.** If you pass it, it is silently dropped. That field records a human overruling a gate, and it is only worth what the guarantee that a machine did not write it is worth. It is added from Zimmer's web UI, which is the one surface no agent tool and no API key reaches. Read them with `search_gate_decisions { with_human_feedback: true }` or `get_gate_decision_feedback`.

        **Rows are append-only.** There is no edit and no delete, here or anywhere. A re-rate or a correction is a NEW call on the same artifact — say so in the entry (`"decision": "correction"`, and cite the earlier decision's id in your reasoning) so both readings stay visible.

        **Who wrote it is stamped, not stated.** The recording session comes from this MCP connection. There is no parameter for it.

        **Returns:** the stored decision's id and the promoted fields, so you can cite it.
      DESC

      input_schema({
        type: "object",
        properties: {
          gate: {
            type: "string",
            enum: GateDecision::GATES,
            description: 'Which gate is recording. "pr_merge" for pr-merge-gate, "issue_work" for issue-work-gate.'
          },
          surface: {
            type: "string",
            description: 'The agent root / repo you rated on — "zimmer", "strad_production", "artifacts", … This is what `search_gate_decisions` filters on, so use the same spelling the ledger already uses for that surface.'
          },
          entry: {
            type: "object",
            description: "The decision itself, in your gate's own schema. Stored verbatim. Include at minimum the artifact URL (`pr` for pr_merge, `issue` for issue_work), `title`, `decided_at` (ISO date), `decision` and `reason`. `human_feedback` is dropped if present."
          }
        },
        required: [ "gate", "surface", "entry" ]
      })

      def call(args)
        entry = args["entry"]
        raise ToolError, "entry must be a JSON object holding the decision" unless entry.is_a?(Hash)

        result = GateDecisions::Record.call(
          gate: require_arg(args, "gate"),
          surface: require_arg(args, "surface"),
          entry: entry,
          recorded_via: GateDecision::MCP,
          # Server-side, from the connection. See the class comment: there is
          # deliberately no argument that could set this.
          writing_session: connection_session
        )

        format_receipt(result.decision, entry)
      rescue GateDecisions::Record::InvalidEntry => e
        raise ToolError, "The decision was rejected and nothing was written: #{e.message}"
      end

      private

      # The session this MCP connection was written for, or nil. Nil is a correct
      # answer — a human driving this tool from an MCP client is not a session —
      # and it is never fatal: the decision is the record, the session link is
      # provenance.
      def connection_session
        return nil unless context.self_session_id

        Session.find_by(id: context.self_session_id)
      end

      def format_receipt(decision, submitted)
        lines = [
          "## Gate decision recorded",
          "",
          "- **Id:** #{decision.id}",
          "- **Gate / surface:** #{decision.gate} / #{decision.surface}",
          "- **Decision:** #{decision.decision || '(none in the entry)'}",
          "- **Decided:** #{decision.decided_at&.iso8601 || '(no parseable decided_at in the entry)'}"
        ]
        lines << "- **Artifact:** #{decision.artifact_url || '(no artifact URL found in the entry)'}"
        lines << "- **Producing session:** #{decision.producing_session_url}" if decision.producing_session_url.present?
        lines << "- **Recorded by session:** #{decision.writing_session_id || '(this connection names no session)'}"

        if submitted.key?("human_feedback")
          lines << ""
          lines << "⚠️ **`human_feedback` was dropped.** No machine path can write it — it records a human " \
                   "overruling a gate, and it is only worth what that guarantee is worth. A human adds one " \
                   "from Zimmer's web UI."
        end

        if decision.artifact_url.blank?
          lines << ""
          lines << "⚠️ **No artifact URL was found in the entry**, so this row cannot be found by artifact. " \
                   "pr_merge reads `pr`; issue_work reads `issue`. Record a correcting entry with the URL " \
                   "if that was a mistake — rows are append-only, so this one stays."
        end

        lines.join("\n")
      end
    end
  end
end
