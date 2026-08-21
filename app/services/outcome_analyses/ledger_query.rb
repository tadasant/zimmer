# frozen_string_literal: true

module OutcomeAnalyses
  # The Outcomes ledger: archived sessions, left-joined to their current
  # analysis, narrowed by LedgerFilters.
  #
  # Two things this deliberately does NOT do, both for the same reason (a
  # deployment with thousands of archived sessions has to render this page in
  # one query, not one query per row):
  #
  #   * it never selects `outcome_analyses.root`, so a page of 50 rows carries 50
  #     small scalar sets rather than 50 Segment trees;
  #   * it reads the analysis's denormalized columns off the join, so a row can
  #     say "Success, 14 segments, 3 failed" without loading an OutcomeAnalysis
  #     object at all.
  #
  # Only ARCHIVED sessions are analyzable — a transcript that is still being
  # written is not a transcript yet — and the analysis sessions Zimmer spawns for
  # this feature are excluded, since analyzing an analysis is not a thing anyone
  # wants a ledger row for.
  class LedgerQuery
    include SessionSearchable

    # What the ledger renders per row. Kept explicit so adding a column to
    # `sessions` never silently widens this page's payload.
    SESSION_COLUMNS = %w[
      id slug title created_at archived_at agent_runtime git_root subdirectory metadata config
    ].freeze

    ANALYSIS_COLUMNS = {
      "analysis_id" => "outcome_analyses.id",
      "analysis_root_outcome" => "outcome_analyses.root_outcome",
      "analysis_segment_count" => "outcome_analyses.segment_count",
      "analysis_failure_segment_count" => "outcome_analyses.failure_segment_count",
      "analysis_max_depth" => "outcome_analyses.max_depth",
      "analysis_analyzed_at" => "outcome_analyses.analyzed_at",
      "analysis_agent_root" => "outcome_analyses.agent_root",
      "analysis_model" => "outcome_analyses.model"
    }.freeze

    CURRENT_ANALYSIS_JOIN = <<~SQL.squish
      LEFT JOIN outcome_analyses
        ON outcome_analyses.session_id = sessions.id
       AND outcome_analyses.superseded_at IS NULL
    SQL

    attr_reader :filters

    def initialize(filters)
      @filters = filters
    end

    # Sessions matching the filters, newest first, with the analysis columns
    # attached. Use for rendering.
    def rows
      base
        .joins(CURRENT_ANALYSIS_JOIN)
        .select(select_list)
        .order("sessions.created_at DESC, sessions.id DESC")
        .then { |scope| apply_analysis_filters(scope) }
    end

    # The ids "Analyze All" would enqueue: everything the filters match that does
    # not already have a current analysis. Deliberately narrower than #rows —
    # re-analyzing what is already analyzed is a per-row decision, not a
    # thousand-session one.
    def analyzable_session_ids
      apply_analysis_filters(base.joins(CURRENT_ANALYSIS_JOIN))
        .where(outcome_analyses: { id: nil })
        .order("sessions.created_at DESC, sessions.id DESC")
        .pluck("sessions.id")
    end

    # Counts for the header line, in one round trip rather than three.
    def counts
      row = apply_analysis_filters(base.joins(CURRENT_ANALYSIS_JOIN))
        .pick(Arel.sql("COUNT(*), COUNT(outcome_analyses.id)"))
      total, analyzed = row || [ 0, 0 ]
      { total: total.to_i, analyzed: analyzed.to_i, unanalyzed: total.to_i - analyzed.to_i }
    end

    # Distinct models seen on archived sessions, for the filter dropdown. Cheap
    # against the (config->>'model') expression index added with this feature.
    # Narrowed the same way #base is: a model only the feature's own analysis
    # sessions ever ran under would otherwise be offered as a filter that can
    # only ever match zero rows.
    def self.model_options
      Session.archived
        .excluding_status_summary_forks
        .excluding_outcome_analysis_sessions
        .where.not("config->>'model' IS NULL")
        .distinct
        .pluck(Arel.sql("config->>'model'"))
        .compact_blank
        .sort
    end

    private

    def select_list
      session_select = SESSION_COLUMNS.map { |c| "sessions.#{c}" }
      analysis_select = ANALYSIS_COLUMNS.map { |alias_name, expr| "#{expr} AS #{alias_name}" }
      Arel.sql((session_select + analysis_select).join(", "))
    end

    def base
      scope = Session.archived.excluding_status_summary_forks.excluding_outcome_analysis_sessions
      scope = scope.where(sessions: { created_at: filters.from_time.. }) if filters.from_time
      scope = scope.where(sessions: { created_at: ..filters.to_time }) if filters.to_time
      scope = scope.where(sessions: { agent_runtime: filters.agent_runtime }) if filters.agent_runtime
      scope = scope.where("sessions.config->>'model' = ?", filters.model) if filters.model
      scope = filter_sessions_by_agent_root(scope, filters.agent_root) if filters.agent_root
      scope
    end

    # Applied after the join, because both of these are predicates on the joined
    # analysis rather than on the session.
    def apply_analysis_filters(scope)
      case filters.analyzed
      when LedgerFilters::ANALYZED_YES then scope = scope.where.not(outcome_analyses: { id: nil })
      when LedgerFilters::ANALYZED_NO then scope = scope.where(outcome_analyses: { id: nil })
      end

      unless filters.outcome == LedgerFilters::OUTCOME_ANY
        scope = scope.where(outcome_analyses: { root_outcome: filters.outcome })
      end

      scope
    end
  end
end
