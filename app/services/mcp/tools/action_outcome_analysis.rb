# frozen_string_literal: true

module Mcp
  module Tools
    # The write side of the Outcomes view — the three things its buttons do:
    # Analyze (one transcript), Analyze All (a batch over the current filters), and
    # Stop (cancel a batch). Mirrors OutcomesController#analyze, #analyze_all and
    # #cancel_batch, and calls the same services, so a batch started here has a
    # batch row, a concurrency ceiling, a Stop button and a card on /outcomes
    # exactly like one started from the page.
    #
    # Where it deliberately differs from the web UI, all of it because the caller
    # is not a human at a keyboard who can see the ledger:
    #
    #   * it lives in the OPT-IN `outcome_analyses` tool group (see Mcp::Registry),
    #     so a session holds it only when someone gave it that server on purpose;
    #   * a batch runs at most OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY
    #     analyses at a time, and only one MCP-started batch runs at once;
    #   * analyze_all takes the number of sessions the caller expects to queue and
    #     refuses a batch of any other size — the web form's confirm dialog;
    #   * single analyses are capped the same way, so a loop of `analyze` calls
    #     cannot become a batch with no Stop button;
    #   * a stopped MCP batch's in-flight analyses block a new MCP batch until
    #     they land, so stop-and-restart cannot widen the ceiling.
    #
    # Both analysis actions spawn under OutcomeAnalyses::Config.agent_root, so a
    # connection fenced by allowed_agent_roots has to be allowed that root.
    class ActionOutcomeAnalysis < Tool
      include OutcomeLedgerFilterArguments

      tool_name "action_outcome_analysis"

      ACTIONS = %w[analyze analyze_all cancel_batch].freeze

      # A batch only ever queues the unanalyzed subset — what the Analyze All
      # button does whatever the ledger's own filters say — so these two can only
      # narrow it to nothing, and are not offered.
      BATCH_EXCLUDED_FILTERS = %i[analyzed outcome].freeze

      description <<~DESC
        Start or stop outcome analyses of archived Zimmer sessions — the Analyze, Analyze All and
        Stop buttons of the web UI's Outcomes view.

        An analysis is a full `spot`-classed agent session that reads one archived transcript,
        decomposes it into a tree of Transcript Segments, and saves the tree back with
        `save_outcome_analysis`. It costs a real session's worth of quota, which is why Zimmer never
        starts one on its own — only this tool and the web UI do. Read results with
        `get_outcome_analysis`.

        **Actions:**
        - **analyze**: Analyze ONE archived session (requires "session_id"). If it already has an
          analysis, the new one supersedes it when it saves. Refused while another analysis of the
          same session is still in flight.
        - **analyze_all**: Queue an analysis of every UNANALYZED archived session matching the
          filters, run as a batch (requires "expected_count"; optional "concurrency" and the
          filters). The membership is frozen when the batch is created. Returns the batch id;
          watch it with `get_outcome_analysis` view "batches".
        - **cancel_batch**: Stop a running batch (requires "batch_id"). Queued analyses are
          canceled; the ones already in flight are left to finish and still save, because killing
          them would throw away work already paid for. Any batch can be stopped, including one a
          human started from the web UI.

        **Limits on this tool that the web UI does not have:**
        - A batch runs at most #{OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY} analyses at a time
          ("concurrency", default 1 — fully sequential). Asking for more is refused, not clamped; a
          human can start a wider batch from the Outcomes page.
        - Only one batch started over MCP runs at a time. Wait for it to finish, or stop it. A stopped
          MCP batch whose analyses are still in flight also blocks a new one until they finish, so
          stopping and restarting does not widen the ceiling.
        - "expected_count" must equal the number of sessions the filters would queue — read it
          first as `counts.unanalyzed` from `get_outcome_analysis` view "ledger" with the same
          filters. A mismatch is refused with the real number and nothing is queued. This is the
          MCP half of the confirm dialog a human sees: a filter left out or mistyped silently widens
          a batch, and stating the number is how you catch that before it spawns anything.
        - At most #{OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY} single "analyze" requests may be in
          flight at once. For more than a handful of transcripts, use analyze_all.
        - An analysis that has produced nothing for #{OutcomeAnalyses::PumpBatch::STALE_AFTER.inspect}
          stops counting against these limits.

        **Filters** (analyze_all): `from`, `to`, `agent_root`, `agent_runtime`, `model` — with the
        same meaning as in `get_outcome_analysis`'s ledger view. (`analyzed` and `outcome` are not
        inputs: a batch only ever queues sessions with no analysis yet, which have no outcome.) A
        value that names nothing is refused rather than dropped. With no filters at all, the batch
        covers every unanalyzed archived session in the deployment — which is what expected_count
        is there to make you notice.

        Zimmer's own analysis sessions are never analyzed: a batch never queues one, and "analyze"
        refuses one.
      DESC

      input_schema({
        type: "object",
        properties: {
          action: {
            type: "string",
            enum: ACTIONS,
            description: "Action to perform."
          },
          session_id: {
            type: [ "integer", "string" ],
            description: "analyze: the archived session to analyze. Numeric id or slug."
          },
          expected_count: {
            type: "integer",
            minimum: 1,
            description: "analyze_all: how many sessions you expect the batch to queue — counts.unanalyzed from get_outcome_analysis view \"ledger\" with the same filters. A batch of any other size is refused."
          },
          concurrency: {
            type: "integer",
            minimum: OutcomeAnalysisBatch::MIN_CONCURRENCY,
            description: "analyze_all: analyses in flight at once, 1 to #{OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY}. Default 1."
          },
          **OutcomeLedgerFilterArguments::PROPERTIES.except(*BATCH_EXCLUDED_FILTERS),
          batch_id: {
            type: "integer",
            description: "cancel_batch: the batch to stop."
          }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, :action)

        case action
        when "analyze" then analyze(args)
        when "analyze_all" then analyze_all(args)
        when "cancel_batch" then cancel_batch(args)
        else
          raise ToolError, "Unknown action \"#{action}\". Valid actions: #{ACTIONS.join(', ')}"
        end
      end

      private

      def analyze(args)
        enforce_allowed_root!(OutcomeAnalyses::Config.agent_root)
        raise ToolError, "\"session_id\" is required for the \"analyze\" action." if args["session_id"].blank?

        target = find_session(args["session_id"])
        if target.metadata&.dig(Session::OUTCOME_ANALYSIS_MARKER).present?
          raise ToolError, "Session ##{target.id} is itself an outcome analysis session; those are not analyzed."
        end

        superseding = OutcomeAnalysis.current.exists?(session_id: target.id)
        analysis_session = OutcomeAnalyses::SpawnAnalysisSession.call(
          session: target,
          requested_via: OutcomeAnalysisBatch::STARTED_VIA_MCP,
          requested_by: calling_session
        )

        lines = [
          "## Analysis started",
          "",
          "- **Analyzing:** ##{target.id}#{target.title.present? ? " — #{target.title}" : ''}",
          "- **Analysis session:** ##{analysis_session.id} (#{session_url(analysis_session)}), spot-classed",
          "- **When it finishes:** it saves the result and archives itself. Read it with `get_outcome_analysis` (session_id: #{target.id})."
        ]
        lines << "" << "*Session ##{target.id} already has an analysis; this one supersedes it when it saves.*" if superseding
        lines.join("\n")
      rescue OutcomeAnalyses::SpawnAnalysisSession::Error, AgentRootsConfig::AgentRootNotFoundError => e
        raise ToolError, "Could not start the analysis: #{e.message}"
      end

      def analyze_all(args)
        enforce_allowed_root!(OutcomeAnalyses::Config.agent_root)
        expected = args["expected_count"]
        if expected.nil?
          raise ToolError, "\"expected_count\" is required for the \"analyze_all\" action: the number of sessions you expect " \
                           "to queue. Read it as counts.unanalyzed from get_outcome_analysis view \"ledger\" with the same filters."
        end

        filters = ledger_filters_from(args.except(*BATCH_EXCLUDED_FILTERS.map(&:to_s)))
        batch = OutcomeAnalyses::StartBatch.call(
          filters: filters,
          concurrency: args["concurrency"] || OutcomeAnalysisBatch::MIN_CONCURRENCY,
          started_via: OutcomeAnalysisBatch::STARTED_VIA_MCP,
          started_by_session: calling_session,
          expected_count: expected.to_i
        )

        [
          "## Batch ##{batch.id} started",
          "",
          "- **Queued:** #{batch.total_count} #{'analysis'.pluralize(batch.total_count)}, #{batch.concurrency} at a time",
          "- **Matching:** #{batch.filter_summary}",
          "- **Watch it:** `get_outcome_analysis` view \"batches\", batch_id #{batch.id} — or the Outcomes page, #{base_url}/outcomes",
          "- **Stop it:** `action_outcome_analysis` action \"cancel_batch\", batch_id #{batch.id}"
        ].join("\n")
      rescue OutcomeAnalyses::StartBatch::Error => e
        raise ToolError, e.message
      end

      def cancel_batch(args)
        raise ToolError, "\"batch_id\" is required for the \"cancel_batch\" action." if args["batch_id"].blank?

        batch = OutcomeAnalysisBatch.find_by(id: args["batch_id"]) || raise(ToolError, "Batch not found: #{args['batch_id']}")
        canceled = OutcomeAnalyses::CancelBatch.call(batch)

        "## Batch ##{batch.id} stopped\n\n" \
          "- **Canceled:** #{canceled} queued #{'analysis'.pluralize(canceled)}\n" \
          "- **Still in flight:** #{batch.reload.running_count}, left to finish and save"
      rescue OutcomeAnalyses::CancelBatch::NotRunning => e
        raise ToolError, e.message
      end

      # The session this MCP connection was written for, when it names one. The
      # batch and the analysis sessions record it, so a human reading /outcomes
      # can see which session started what.
      def calling_session
        return @calling_session if defined?(@calling_session)

        @calling_session = context.self_session_id && Session.find_by(id: context.self_session_id)
      end

      def base_url = context.base_url.chomp("/")
    end
  end
end
