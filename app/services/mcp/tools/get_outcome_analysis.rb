# frozen_string_literal: true

module Mcp
  module Tools
    # The read side of the Outcomes view: everything /outcomes, /outcomes/:id and
    # /outcomes/stats render, plus the batch queue the ledger shows above its
    # table.
    #
    # Read-only, and in the `sessions` group rather than the opt-in
    # `outcome_analyses` group its write counterpart lives in: reading an analysis
    # starts nothing and costs one query, so it rides on every surface that can
    # already read a transcript with get_session — `zimmer`, `zimmer-sessions`,
    # and `sessions_readonly`. Not on self_session: an analysis exists only for an
    # archived session, so there is no "my own analysis" for a live session to
    # read, and the fleet-wide read is not a self-management tool.
    #
    # Like get_session on the same group, it reads any session on a connection
    # restricted by allowed_agent_roots — that fence governs what a connection may
    # spawn or drive, not what it may read.
    class GetOutcomeAnalysis < Tool
      include OutcomeLedgerFilterArguments

      tool_name "get_outcome_analysis"

      VIEWS = %w[analysis ledger stats goal_checks batches].freeze

      # The ledger's page size on /outcomes.
      LEDGER_PAGE_SIZE = 50
      DEFAULT_BATCH_LIMIT = 5
      MAX_BATCH_LIMIT = 50
      WORST_TRANSCRIPTS = 10
      FAILED_ITEM_LIMIT = 50

      description <<~DESC
        Read Zimmer's outcome analyses: what an analysis said about an archived session's
        transcript, which transcripts failed, how outcomes break down across the fleet, and what
        the Analyze All batches are doing. The same data the web UI's Outcomes view renders.

        An outcome analysis decomposes one archived transcript into a tree of **Transcript
        Segments** — `Trigger → Goal → Outcome` triplets that nest, with the whole transcript as
        the root Segment `S0`. Each Segment's Outcome is `Success` or `Failure` against its OWN
        Goal, so a Failure Segment under a Success parent is normal: the transcript recovered, and
        the failed Segment is where it went wrong.

        Reading never starts an analysis. Zimmer analyzes nothing implicitly; `action_outcome_analysis`
        starts one, and only on a connection that opted into that tool.

        **Views** (`view`; defaults to "analysis" when `session_id` is given, else "ledger"):

        - **analysis** — one session's current analysis WITH its Segment tree (`session_id`
          required). Adds `failed_segments`, a flat depth-first list of every Failure Segment's
          id, Goal and explanation — the "where did it fail" answer without walking the tree —
          and the superseded earlier analyses of the same session, without their trees. For a
          session that has not been analyzed, `analysis` is null and `analysis_in_flight` names
          the analysis session working on it, if any.
        - **ledger** — archived sessions matching the filters, newest first, #{LEDGER_PAGE_SIZE} per
          `page`, each with its current analysis's scalar columns (root outcome, segment and
          failure counts) and no tree. `counts` gives the whole filtered set: `total`, `analyzed`,
          `unanalyzed` — and `unanalyzed` is exactly how many sessions `analyze_all` would queue
          for the same filters. Zimmer's own analysis sessions are never listed.
        - **stats** — aggregates over the CURRENT analyses matching the filters: totals, one row
          per `group_by` value (#{OutcomeAnalyses::Stats::GROUPINGS.keys.map { |key| "\"#{key}\"" }.join(', ')};
          default "#{OutcomeAnalyses::Stats::DEFAULT_GROUPING}") with transcript and segment success
          rates, the distribution of failed-segment counts, and the #{WORST_TRANSCRIPTS} most
          failure-heavy transcripts. No tree is loaded. Grouping reads the agent root, harness and
          model recorded on the analysis when it was saved.
        - **goal_checks** — how the advisory goal check read on sessions that came to rest
          (`needs_input` or `archived`) in the window, the web UI's /outcomes/goal_checks: verdict
          counts, per-criterion statuses, sessions grouped by the criteria that kept them from
          `met` (with sample ids), rows by agent root and by goal, how many were judged on PRs a
          spawned session recorded, and `unmet_on_own_pull_request` — the sessions at rest that
          are unmet only on what their own PR shows on GitHub. Filters apply except `analyzed` and
          `outcome`; with no dates it covers the last 7 days. No analysis is involved.
        - **batches** — the most recent Analyze All batches (`limit`, default #{DEFAULT_BATCH_LIMIT}),
          each with its status, who started it (web UI or MCP, and which session), its concurrency,
          the filters it was created from, and live item counts. With `batch_id`, that one batch
          plus the error on each of its failed items. Also reports the MCP limits in force
          (`agent_limits`), so a caller can see before `analyze_all` whether it would be refused.

        **Filters** (ledger, stats and goal_checks): `from`, `to`, `agent_root`, `agent_runtime`, `model`,
        `analyzed`, `outcome`. All optional and ANDed. A value that names nothing (an unparseable
        date, an unknown runtime) is refused rather than dropped. Every response echoes the
        filters it applied.

        **Example** — "which of last week's transcripts failed, and where":
        `{view: "ledger", from: "2026-09-01", to: "2026-09-07", outcome: "Failure"}`, then
        `{session_id: <each one>}` for its `failed_segments`.

        Returns JSON.
      DESC

      input_schema({
        type: "object",
        properties: {
          view: {
            type: "string",
            enum: VIEWS,
            description: "Which view to read. Defaults to \"analysis\" when session_id is given, otherwise \"ledger\"."
          },
          session_id: {
            type: [ "integer", "string" ],
            description: "The analyzed session, numeric id or slug. Required for the analysis view."
          },
          **OutcomeLedgerFilterArguments::PROPERTIES,
          group_by: {
            type: "string",
            enum: OutcomeAnalyses::Stats::GROUPINGS.keys,
            description: "Stats view: the dimension to break the rows down by. Default \"#{OutcomeAnalyses::Stats::DEFAULT_GROUPING}\"."
          },
          page: {
            type: "integer",
            minimum: 1,
            description: "Ledger view: the 1-based page, #{LEDGER_PAGE_SIZE} rows each. Default 1."
          },
          batch_id: {
            type: "integer",
            description: "Batches view: read this one batch, with its failed items' errors, instead of the recent list."
          },
          limit: {
            type: "integer",
            minimum: 1,
            maximum: MAX_BATCH_LIMIT,
            description: "Batches view: how many recent batches. Default #{DEFAULT_BATCH_LIMIT}."
          }
        }
      })

      def call(args)
        view = args["view"].presence || (args["session_id"].present? ? "analysis" : "ledger")

        case view
        when "analysis" then analysis_view(args)
        when "ledger" then ledger_view(args)
        when "stats" then stats_view(args)
        when "goal_checks" then goal_checks_view(args)
        when "batches" then batches_view(args)
        else
          raise ToolError, "Unknown view \"#{view}\". Valid views: #{VIEWS.join(', ')}"
        end
      end

      private

      # --- analysis ---------------------------------------------------------------

      def analysis_view(args)
        raise ToolError, "The analysis view needs a session_id." if args["session_id"].blank?

        session = find_session(args["session_id"])
        analysis = OutcomeAnalysis.current.find_by(session_id: session.id)

        result = {
          session: session_ref(session).merge(status: session.status, archived: session.archived?),
          analysis: analysis && analysis_json(analysis, include_tree: true)
        }

        if analysis
          result[:failed_segments] = failed_segments(analysis)
          result[:previous_analyses] = previous_analyses(session)
          result[:view_url] = "#{base_url}/outcomes/#{session.id}"
        else
          in_flight = OutcomeAnalyses::SpawnAnalysisSession.in_flight_for(session)
          result[:analysis_in_flight] = in_flight && session_ref(in_flight).merge(status: in_flight.status)
          result[:note] = not_analyzed_note(session, in_flight)
        end

        result
      end

      def failed_segments(analysis)
        failures = []
        analysis.each_segment do |segment, depth|
          next unless segment.dig("outcome", "kind") == OutcomeAnalyses::SegmentTree::FAILURE

          failures << {
            id: segment["id"],
            depth: depth,
            trigger: segment["trigger"],
            goal: segment.dig("goal", "text"),
            explanation: segment.dig("outcome", "explanation")
          }
        end
        failures
      end

      def previous_analyses(session)
        OutcomeAnalysis.superseded
          .without_tree
          .where(session_id: session.id)
          .order(analyzed_at: :desc)
          .limit(10)
          .map { |analysis| analysis_json(analysis) }
      end

      def not_analyzed_note(session, in_flight)
        return "Not analyzed yet. Session ##{in_flight.id} is analyzing it now and saves the result here when it finishes." if in_flight
        return "Not analyzed. Only archived sessions can be analyzed, and this one is #{session.status}." unless session.archived?

        "Not analyzed yet."
      end

      # --- ledger -----------------------------------------------------------------

      def ledger_view(args)
        filters = ledger_filters_from(args)
        query = OutcomeAnalyses::LedgerQuery.new(filters)
        page = [ args["page"].to_i, 1 ].max

        # One row over the page size, so "is there a next page" costs a row rather
        # than a second COUNT — the same trick the ledger page uses.
        rows = query.rows.limit(LEDGER_PAGE_SIZE + 1).offset((page - 1) * LEDGER_PAGE_SIZE).to_a

        {
          filters: filters_json(filters),
          counts: query.counts,
          page: page,
          per_page: LEDGER_PAGE_SIZE,
          has_next_page: rows.size > LEDGER_PAGE_SIZE,
          rows: rows.first(LEDGER_PAGE_SIZE).map { |row| ledger_row_json(row) }
        }
      end

      def ledger_row_json(row)
        {
          session_id: row.id,
          title: row.title,
          url: session_url(row),
          created_at: row.created_at&.iso8601,
          archived_at: row.archived_at&.iso8601,
          agent_root: row.metadata&.dig("agent_root_key") || row.agent_root_key,
          agent_runtime: row.agent_runtime,
          model: row.config&.dig("model"),
          analysis: row.analysis_id && {
            id: row.analysis_id,
            root_outcome: row.analysis_root_outcome,
            segment_count: row.analysis_segment_count,
            failure_segment_count: row.analysis_failure_segment_count,
            max_depth: row.analysis_max_depth,
            analyzed_at: row.analysis_analyzed_at&.iso8601
          }
        }
      end

      # --- stats ------------------------------------------------------------------

      def stats_view(args)
        filters = ledger_filters_from(args)
        stats = OutcomeAnalyses::Stats.new(filters: filters, grouping: args["group_by"])

        {
          filters: filters_json(filters),
          group_by: stats.grouping,
          group_by_label: stats.grouping_label,
          totals: stats_row_json(stats.totals),
          rows: stats.rows.map { |row| stats_row_json(row) },
          failure_distribution: stats.failure_distribution,
          worst_transcripts: stats.worst_transcripts(limit: WORST_TRANSCRIPTS).map do |analysis|
            analysis_json(analysis).merge(title: analysis.session&.title)
          end
        }
      end

      # --- goal checks --------------------------------------------------------------

      def goal_checks_view(args)
        filters = ledger_filters_from(args)
        tally = GoalCheckTally.new(filters: filters)

        { filters: filters_json(filters), view_url: "#{base_url}/outcomes/goal_checks" }.merge(tally.to_h)
      end

      def stats_row_json(row)
        {
          key: row.key,
          label: row.label,
          transcripts: row.transcripts,
          successes: row.successes,
          failures: row.failures,
          segments: row.segments,
          failed_segments: row.failed_segments,
          transcript_success_rate: row.transcript_success_rate&.round(4),
          segment_success_rate: row.segment_success_rate&.round(4),
          avg_failed_segments: row.avg_failed_segments.round(2)
        }
      end

      # --- batches ----------------------------------------------------------------

      def batches_view(args)
        result =
          if args["batch_id"].present?
            batch = OutcomeAnalysisBatch.find_by(id: args["batch_id"]) ||
              raise(ToolError, "Batch not found: #{args['batch_id']}")
            { batch: batch_json(batch).merge(failed_items: failed_items(batch)) }
          else
            limit = (args["limit"].presence || DEFAULT_BATCH_LIMIT).to_i.clamp(1, MAX_BATCH_LIMIT)
            { batches: OutcomeAnalysisBatch.recent.limit(limit).map { |batch| batch_json(batch) } }
          end

        result.merge(agent_limits: agent_limits)
      end

      def failed_items(batch)
        batch.items.where(state: OutcomeAnalysisBatchItem::FAILED).in_order.limit(FAILED_ITEM_LIMIT).map do |item|
          { session_id: item.session_id, analysis_session_id: item.analysis_session_id, error: item.error }
        end
      end

      def agent_limits
        running = OutcomeAnalysisBatch.active.started_via_mcp.recent.first
        {
          max_batch_concurrency: OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY,
          running_mcp_batch_id: running&.id,
          # Running or stopped: while any are in flight, a new MCP batch is refused.
          mcp_batch_analyses_in_flight: OutcomeAnalyses::SpawnAnalysisSession.live_mcp_batch_item_count,
          max_single_analyses_in_flight: OutcomeAnalysisBatch::AGENT_MAX_CONCURRENCY,
          single_analyses_in_flight: OutcomeAnalyses::SpawnAnalysisSession.live_mcp_single_count
        }
      end

      # --- shared -----------------------------------------------------------------

      def batch_json(batch)
        {
          id: batch.id,
          status: batch.status,
          started_via: batch.started_via,
          started_by_session_id: batch.started_by_session_id,
          concurrency: batch.concurrency,
          filters: batch.filters,
          filter_summary: batch.filter_summary,
          total_count: batch.total_count,
          counts: {
            queued: batch.queued_count,
            running: batch.running_count,
            succeeded: batch.succeeded_count,
            failed: batch.failed_count,
            canceled: batch.canceled_count
          },
          progress_percent: batch.progress_percent,
          created_at: batch.created_at&.iso8601,
          finished_at: batch.finished_at&.iso8601
        }
      end

      # The same fields GET /api/v1/outcome_analyses/:id renders, so a caller that
      # moves between the two surfaces reads one shape.
      def analysis_json(analysis, include_tree: false)
        json = {
          id: analysis.id,
          session_id: analysis.session_id,
          analyzer_session_id: analysis.analyzer_session_id,
          schema_version: analysis.schema_version,
          notes: analysis.notes,
          agent_root: analysis.agent_root,
          agent_runtime: analysis.agent_runtime,
          model: analysis.model,
          session_created_at: analysis.session_created_at&.iso8601,
          root_outcome: analysis.root_outcome,
          segment_count: analysis.segment_count,
          failure_segment_count: analysis.failure_segment_count,
          success_segment_count: analysis.success_segment_count,
          max_depth: analysis.max_depth,
          analyzed_at: analysis.analyzed_at&.iso8601,
          superseded_at: analysis.superseded_at&.iso8601
        }
        json[:root] = analysis.root if include_tree
        json
      end

      def session_ref(session)
        { id: session.id, title: session.title, url: session_url(session) }
      end

      def base_url = context.base_url.chomp("/")
    end
  end
end
