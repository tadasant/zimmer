# frozen_string_literal: true

module Mcp
  module Tools
    # The Outcomes ledger's filter set as MCP arguments, shared by
    # get_outcome_analysis (its ledger and stats views) and action_outcome_analysis
    # (analyze_all). Both build an OutcomeAnalyses::LedgerFilters — the same struct
    # the /outcomes page builds from its query string — so a filter means one thing
    # on every surface.
    #
    # One difference from the web form, on purpose. LedgerFilters drops a value it
    # cannot parse rather than raising, which is right for a hand-edited query
    # string and wrong for an agent: a dropped `from` silently widens the set, and
    # on analyze_all that is a batch over sessions nobody asked about. So a value
    # that names nothing is refused here, with the reason, before LedgerFilters
    # ever sees it.
    module OutcomeLedgerFilterArguments
      PROPERTIES = {
        from: {
          type: "string",
          description: "Only sessions CREATED on or after this date (YYYY-MM-DD). The window is on the analyzed session's creation date — what \"last week's sessions\" means — not on when it was analyzed."
        },
        to: {
          type: "string",
          description: "Only sessions created on or before this date (YYYY-MM-DD), inclusive of the whole day."
        },
        agent_root: {
          type: "string",
          description: "Only sessions under this agent root (its catalog name, as get_configs lists it)."
        },
        agent_runtime: {
          type: "string",
          description: "Only sessions on this harness: \"claude_code\" or \"codex\"."
        },
        model: {
          type: "string",
          description: "Only sessions that ran on this model id, exactly as recorded on the session — the ledger view's `model` field shows the values in use."
        },
        analyzed: {
          type: "string",
          enum: OutcomeAnalyses::LedgerFilters::ANALYZED_VALUES,
          description: "\"no\": not yet analyzed. \"yes\": already analyzed. \"any\" (the default): both. The stats view only ever reads analyzed sessions, so it ignores this."
        },
        outcome: {
          type: "string",
          enum: [ OutcomeAnalyses::LedgerFilters::OUTCOME_ANY, *OutcomeAnalyses::SegmentTree::OUTCOME_KINDS ],
          description: "Only transcripts whose ROOT Segment has this outcome. \"any\" (the default) does not filter."
        }
      }.freeze

      private

      # @return [OutcomeAnalyses::LedgerFilters]
      # @raise [Mcp::ToolError] when a value is present but names nothing
      def ledger_filters_from(args)
        %w[from to].each do |key|
          next if args[key].blank?

          Date.iso8601(args[key].to_s)
        rescue ArgumentError, TypeError
          raise ToolError, "\"#{key}\" must be a date in YYYY-MM-DD form; got #{args[key].inspect}."
        end

        runtime = args["agent_runtime"].to_s.strip
        if runtime.present? && !RuntimeRegistry.registered_runtimes.include?(runtime)
          raise ToolError, "Unknown agent_runtime #{runtime.inspect}. " \
                           "Valid runtimes: #{RuntimeRegistry.registered_runtimes.join(', ')}"
        end

        OutcomeAnalyses::LedgerFilters.from_params(
          args.slice(*PROPERTIES.keys.map(&:to_s)).symbolize_keys
        )
      end

      # What the filters resolved to, echoed in every response that used them, so
      # a caller can see the set it actually got rather than the one it meant.
      def filters_json(filters)
        { applied: filters.to_h, summary: filters.summary }
      end
    end
  end
end
