# frozen_string_literal: true

module Mcp
  module Tools
    # Save an analysis session's Transcript-Segment tree for an archived session.
    #
    # This is one of the two write paths for the Outcomes view (the other is
    # POST /api/v1/outcome_analyses), and both go through OutcomeAnalyses::Save.
    # Zimmer never runs this analysis itself: the tool exists so that a session
    # spawned by an explicit Analyze click can hand its result back.
    #
    # It lives in the `sessions` tool group, which means the already-registered
    # `zimmer` and `zimmer-sessions` catalog servers pick it up with no change to
    # the AIR catalog's mcp.json — `zimmer-sessions` (`?tool_groups=sessions`)
    # being the least-privileged server that carries it.
    class SaveOutcomeAnalysis < Tool
      tool_name "save_outcome_analysis"

      SEGMENT_SHAPE = <<~TEXT.strip
        Segment {
          id:      string,                        // "S0", "S0.0", "S0.1.2", … depth-first positional
          trigger: { kind: "New" | "Correction", source: "user" | "agent" | "subagent" },
          goal:    { text: string, kind: "Plan" | "Action" },
          outcome: { kind: "Success" | "Failure", explanation: string },
          meta:    { event_range: [string, string] | null, wall_clock_s: number | null,
                     tokens_in: number | null, tokens_out: number | null, model: string | null },
          children: Segment[]                     // [] for leaves
        }
      TEXT

      description <<~DESC
        Save the outcome analysis of one archived Zimmer session's transcript.

        **Only archived sessions can be analyzed.** A transcript that is still being written is
        rejected.

        **Saving twice supersedes.** A second analysis of the same session replaces the first as
        the current one; the earlier reading is kept, stamped as superseded. Nothing is
        duplicated, so a retry after a validation failure is safe.

        **The Segment tree.** A Transcript Segment is one coherent unit of agent work, described
        by a `Trigger → Goal → Outcome` triplet. Segments nest; the whole transcript is the root
        Segment.

        ```
        #{SEGMENT_SHAPE}
        ```

        - **Outcome is local to the Goal.** A Failure Segment under a Success parent is normal and
          expected — failures do NOT propagate up. That contrast is the signal this whole feature
          exists to surface, so do not soften a failed Segment because the transcript recovered
          later, and do not fail a parent because a child failed.
        - **Ids are positional and validated.** Root is `S0`; the children of `S0` are `S0.0`,
          `S0.1`, …; the children of `S0.1` are `S0.1.0`, …. Depth-first. A tree whose ids do not
          match its shape is rejected.
        - **`trigger.kind: "Correction"`** means the PRIOR SIBLING Segment failed to deliver its
          own Goal, so the first child of a parent can never be a Correction.
        - **`outcome.explanation` is required on Success as well as Failure**, and is capped at
          #{OutcomeAnalyses::SegmentTree::EXPLANATION_MAX} characters. It renders as a hover
          tooltip in Zimmer's Outcomes view — one short clause, not a paragraph.
        - Skill recommendations, MCP recommendations, and efficiency analysis are deliberately not
          part of this schema. Extra keys are ignored.

        **Validation.** The whole tree is checked before anything is stored: id scheme, enum
        values, explanation presence and length, nesting. A malformed tree is rejected with every
        problem named, and nothing is written — fix what the error names and call again.

        **Returns:** the saved analysis's id, its root outcome, and its segment counts.
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            type: [ "integer", "string" ],
            description: "The archived Zimmer session that was analyzed. Numeric id or slug."
          },
          analyzer_session_id: {
            type: [ "integer", "null" ],
            description: "The session that produced this analysis — normally your own session id. Null when a human is calling the tool directly."
          },
          schema_version: {
            type: "string",
            description: 'Always "1" for this schema.'
          },
          root: {
            type: "object",
            description: "The root Segment (id \"S0\"), with its Segment children nested under `children`."
          },
          notes: {
            type: [ "string", "null" ],
            description: "One line about the analysis itself — a caveat, an ambiguity, what you could not determine. Not a summary of the transcript."
          }
        },
        required: [ "session_id", "root" ]
      })

      def call(args)
        session = find_session(args["session_id"])
        analyzer = find_analyzer(args["analyzer_session_id"])

        result = OutcomeAnalyses::Save.call(
          session: session,
          root: args["root"],
          analyzer_session: analyzer,
          schema_version: args["schema_version"],
          notes: args["notes"]
        )

        format_result(result, session)
      rescue OutcomeAnalyses::SegmentTree::InvalidTree => e
        raise ToolError, "The Segment tree was rejected and nothing was saved. Fix these and call again:\n" +
          e.errors.map { |error| "  - #{error}" }.join("\n")
      rescue OutcomeAnalyses::Save::UnanalyzableSession => e
        raise ToolError, e.message
      end

      private

      # An analyzer id that names nothing is dropped rather than failing the save.
      # The analysis is the valuable artifact; the provenance link is a nicety,
      # and losing a whole tree over a stale session id would be the wrong trade.
      def find_analyzer(identifier)
        return nil if identifier.blank?

        Session.find_by(id: identifier.to_i) || Session.find_by(slug: identifier.to_s)
      end

      def format_result(result, session)
        analysis = result.analysis
        lines = [
          "## Outcome analysis saved",
          "",
          "- **Session:** ##{session.id}#{session.title.present? ? " — #{session.title}" : ""}",
          "- **Analysis id:** #{analysis.id}",
          "- **Root outcome:** #{analysis.root_outcome}",
          "- **Segments:** #{analysis.segment_count} (#{analysis.failure_segment_count} Failure, #{analysis.success_segment_count} Success)",
          "- **Max depth:** #{analysis.max_depth}",
          "- **View:** #{context.base_url.chomp('/')}/outcomes/#{session.id}"
        ]
        lines << "" << "*This superseded the previous analysis of this session.*" if result.superseded
        lines.join("\n")
      end
    end
  end
end
