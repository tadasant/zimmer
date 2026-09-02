# frozen_string_literal: true

module Mcp
  module Tools
    # Every note a human left on a gate's rating, and nothing else.
    #
    # WHY THIS IS ITS OWN TOOL RATHER THAN A FILTER
    #
    # It is a filter — `search_gate_decisions { with_human_feedback: true }`
    # returns the same decisions. But there are eight of these notes in a corpus
    # of roughly 1,500 decisions, and they are the only place in the ledger where
    # a gate finds out it was wrong. A signal at that ratio does not get read if
    # reading it depends on remembering a boolean, so it gets a name.
    #
    # Read-only, and there is no write counterpart anywhere on the MCP surface.
    # Feedback is written from the browser only; see GateDecisionFeedback.
    class GetGateDecisionFeedback < Tool
      MAX_NOTE_DISPLAY = 4000

      tool_name "get_gate_decision_feedback"

      description <<~DESC
        Every correction a human has made to a gate's rating.

        **Read this before rating anything.** It is the smallest and highest-authority slice of the gate decision ledger: roughly eight notes across ~1,500 decisions, each one a person saying a gate got a call wrong and why. Nothing else in the corpus carries that weight — the rest is the gates' own account of their own reasoning.

        Filter by `gate` and `surface` to see how *this* gate has been corrected on *this* surface, or call it with no arguments to read all of them; the whole set is short enough to read.

        **Verdicts seen so far:** `should-have-merged`, `should-have-held`, `should-have-proceeded`, `mischaracterized`. Each note comes with the decision it corrects, so you can see the rating the human disagreed with.

        **Provenance is part of the answer**, and it is reported per note:
        - `web_ui` — typed into Zimmer by the named human. This is the trustworthy channel: no API key and no MCP tool can write it, only the browser.
        - `imported` — transcribed from the JSON ledgers by the one-time backfill. Same words, older provenance; the source did not always record who said them.

        **Returns:** each note with its verdict, date, author, channel, and the decision it corrects.
      DESC

      input_schema({
        type: "object",
        properties: {
          gate: {
            type: "string",
            enum: GateDecision::GATES,
            description: "Only feedback on decisions this gate made."
          },
          surface: {
            type: "string",
            description: 'Only feedback on decisions made on this surface — "zimmer", "strad", …'
          },
          decision_id: {
            type: "number",
            description: "Only feedback on one specific decision, by its ledger id."
          },
          limit: {
            type: "number",
            minimum: 1,
            maximum: GateDecisions::Filters::MAX_LIMIT,
            description: "How many notes to return, newest first. Default #{GateDecisions::Filters::DEFAULT_LIMIT}, max #{GateDecisions::Filters::MAX_LIMIT}."
          }
        },
        required: []
      })

      def call(args)
        filters = GateDecisions::Filters.new(args.merge("with_human_feedback" => true))
        scope = filters.scope
        scope = scope.where(id: args["decision_id"].to_i) if args["decision_id"].present?

        notes = GateDecisionFeedback
          .where(gate_decision_id: scope.select(:id))
          .includes(:gate_decision)
          .order(received_at: :desc, id: :desc)
          .limit(filters.limit)
          .to_a

        if notes.empty?
          return "No human feedback recorded for #{filters.describe}.\n\n" \
                 "That is the common case — the ledger holds #{GateDecisionFeedback.count} note(s) across " \
                 "#{GateDecision.count} decision(s). Widen the filter, or call this with no arguments to " \
                 "read every note there is."
        end

        lines = [ "## Human feedback on gate decisions", "",
                  "#{notes.size} note(s) for #{filters.describe}, newest first.", "" ]

        notes.each do |note|
          lines << format_note(note)
          lines << ""
        end

        lines.join("\n").strip
      rescue GateDecisions::Filters::InvalidFilter => e
        raise ToolError, e.message
      end

      private

      def format_note(note)
        decision = note.gate_decision
        lines = [
          "### #{note.verdict} — #{note.received_at&.iso8601 || 'undated'}",
          "",
          "- **On decision:** ##{decision.id} — #{decision.gate} / #{decision.surface}, " \
          "decided #{decision.decided_at&.iso8601 || 'undated'} as **#{decision.decision || 'unrecorded'}**"
        ]
        lines << "- **Artifact:** #{decision.artifact_url}" if decision.artifact_url.present?
        lines << "- **Author:** #{note.display_name || 'not recorded in the source'}"
        lines << "- **Channel:** #{note.channel}#{note.channel == GateDecisionFeedback::IMPORTED ? ' (transcribed from the JSON ledger by the backfill)' : ' (typed into Zimmer by a human)'}"
        lines << ""
        lines << (note.note.presence&.truncate(MAX_NOTE_DISPLAY) || "*(no note text recorded)*")
        lines.join("\n")
      end
    end
  end
end
