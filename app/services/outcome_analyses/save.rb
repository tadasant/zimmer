# frozen_string_literal: true

module OutcomeAnalyses
  # The single write path for an outcome analysis, shared by the MCP tool and
  # the REST endpoint so the two cannot drift on validation or on what
  # "re-analyze" means.
  #
  # Re-analysis SUPERSEDES: the prior row is stamped `superseded_at` and a new
  # current row is inserted, inside one transaction, so the partial unique index
  # on (session_id) WHERE superseded_at IS NULL is never violated and there is
  # never a moment with no current analysis. Nothing is silently duplicated, and
  # nothing is silently destroyed either — a second reading that disagrees with
  # the first is a fact worth keeping.
  class Save
    class Error < StandardError; end
    # Raised when the target is not something this feature can analyze.
    class UnanalyzableSession < Error; end

    Result = Data.define(:analysis, :superseded)

    # @param session [Session] the analyzed session
    # @param root [Hash] the Segment tree
    # @param analyzer_session [Session, nil] the session that produced it
    # @param schema_version [String]
    # @param notes [String, nil]
    # @return [Result]
    # @raise [SegmentTree::InvalidTree] the tree is malformed — nothing is stored
    # @raise [UnanalyzableSession] the target is not an archived session
    def self.call(session:, root:, analyzer_session: nil, schema_version: OutcomeAnalysis::SCHEMA_VERSION, notes: nil)
      new(session:, root:, analyzer_session:, schema_version:, notes:).call
    end

    def initialize(session:, root:, analyzer_session:, schema_version:, notes:)
      @session = session
      @root = root
      @analyzer_session = analyzer_session
      @schema_version = schema_version.presence || OutcomeAnalysis::SCHEMA_VERSION
      @notes = notes.presence&.to_s&.slice(0, SegmentTree::NOTES_MAX)
    end

    def call
      ensure_analyzable!
      normalized = SegmentTree.normalize!(@root)
      summary = SegmentTree.summarize(normalized)

      analysis = nil
      superseded = false

      OutcomeAnalysis.transaction do
        # Stamped inside the transaction and before the insert, so the unique
        # index does the arbitration if two analyzers race on the same session:
        # one commits, the other's insert conflicts and it retries or fails
        # loudly rather than both claiming to be current.
        superseded = OutcomeAnalysis.current.where(session_id: @session.id).update_all(
          superseded_at: Time.current, updated_at: Time.current
        ).positive?

        analysis = OutcomeAnalysis.create!(
          session: @session,
          analyzer_session: @analyzer_session,
          schema_version: @schema_version,
          root: normalized,
          notes: @notes,
          agent_root: @session.agent_root_key,
          agent_runtime: @session.agent_runtime,
          model: @session.config&.dig("model"),
          session_created_at: @session.created_at,
          root_outcome: summary.root_outcome,
          segment_count: summary.segment_count,
          failure_segment_count: summary.failure_segment_count,
          max_depth: summary.max_depth,
          analyzed_at: Time.current
        )
      end

      Result.new(analysis: analysis, superseded: superseded)
    end

    private

    # The ledger only ever offers archived sessions, and the MCP tool is reachable
    # by anything holding an API key — so the rules are enforced here rather than
    # in the UI that happens to respect them.
    def ensure_analyzable!
      unless @session.archived?
        raise UnanalyzableSession,
          "Session #{@session.id} is #{@session.status}, not archived. Only archived sessions can be analyzed — " \
          "a transcript that is still being written is not finished enough to have an outcome."
      end

      # Zimmer's own analysis sessions are excluded from the ledger, so an
      # analysis of one would be a row the ledger can never show and the stats
      # view would nonetheless count — the two surfaces would disagree about how
      # many transcripts have been analyzed, for a reading nobody asked for.
      if @session.metadata&.key?(Session::OUTCOME_ANALYSIS_MARKER)
        raise UnanalyzableSession,
          "Session #{@session.id} is itself an outcome-analysis session. Analyzing an analysis is not something " \
          "the Outcomes view can show, so it is refused rather than stored where only the stats would see it."
      end
    end
  end
end
