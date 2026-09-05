# frozen_string_literal: true

# The REST half of the Outcomes view's write surface. Mirrors the
# `save_outcome_analysis` MCP tool exactly — both call OutcomeAnalyses::Save, so
# the two cannot disagree about validation, about what re-analysis means, or
# about which sessions are analyzable.
#
# There is no create-by-side-effect anywhere in Zimmer: an analysis exists
# because something explicitly posted one here or called the tool.
class Api::V1::OutcomeAnalysesController < Api::BaseController
  before_action :set_session, only: [ :create ]

  # GET /api/v1/outcome_analyses
  # Current analyses, newest analysis first. Never returns the Segment trees —
  # fetch one with #show when you want the tree.
  def index
    filters = OutcomeAnalyses::LedgerFilters.from_params(params)
    scope = OutcomeAnalysis.current
      .created_between(filters.from_time, filters.to_time)
      .order(analyzed_at: :desc, id: :desc)
    scope = scope.where(agent_runtime: filters.agent_runtime) if filters.agent_runtime
    scope = scope.where(model: filters.model) if filters.model
    scope = scope.where(agent_root: filters.agent_root) if filters.agent_root
    scope = scope.where(root_outcome: filters.outcome) unless filters.outcome == OutcomeAnalyses::LedgerFilters::OUTCOME_ANY

    # `without_tree` is applied AFTER paginate: it sets an explicit select list,
    # and paginate's COUNT over that list would become COUNT(col, col, …), which
    # Postgres has no such function for. Narrowing the columns here still keeps the
    # Segment trees out of the response — the relation has not been loaded yet.
    result = paginate(scope)
    render json: {
      outcome_analyses: result[:records].without_tree.map { |analysis| analysis_json(analysis) },
      pagination: result[:pagination]
    }
  end

  # GET /api/v1/outcome_analyses/:id
  # One analysis WITH its Segment tree. `:id` is the analyzed session's id or
  # slug, not the analysis row's — the session is what a caller has a handle on.
  def show
    session = Session.locate(params[:id])
    return not_found unless session

    analysis = OutcomeAnalysis.current.find_by(session_id: session.id)
    return not_found unless analysis

    render json: { outcome_analysis: analysis_json(analysis, include_tree: true) }
  end

  # POST /api/v1/outcome_analyses
  #
  # Body:
  #   session_id          - the analyzed (archived) session, id or slug
  #   analyzer_session_id - the session that produced the analysis (optional)
  #   schema_version      - "1"
  #   root                - the recursive Segment tree
  #   notes               - one line about the analysis itself (optional)
  def create
    result = OutcomeAnalyses::Save.call(
      session: @session,
      root: root_param,
      analyzer_session: analyzer_session,
      schema_version: params[:schema_version],
      notes: params[:notes]
    )

    render json: {
      outcome_analysis: analysis_json(result.analysis, include_tree: true),
      superseded_previous: result.superseded
    }, status: :created
  rescue OutcomeAnalyses::SegmentTree::InvalidTree => e
    render_api_error("Invalid Segment tree", e.errors, status: :unprocessable_entity)
  rescue OutcomeAnalyses::Save::UnanalyzableSession => e
    render_api_error("Unanalyzable session", e.message, status: :unprocessable_entity)
  end

  private

  # `params[:root]` arrives as ActionController::Parameters, which is not a Hash
  # and so would be rejected by the validator as "not a Segment object". Converting
  # with to_unsafe_h is safe precisely because nothing here is mass-assigned: the
  # tree is structurally validated key by key by OutcomeAnalyses::SegmentTree, and
  # anything it does not recognize is dropped rather than stored.
  def root_param
    raw = params[:root]
    raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
  end

  def set_session
    @session = Session.locate(params[:session_id])
    return if @session

    render_api_error("Not Found", "No session matches session_id #{params[:session_id].inspect}", status: :not_found)
  end

  # Same forgiving treatment as the MCP tool: a stale analyzer id costs the
  # provenance link, not the analysis.
  def analyzer_session
    Session.locate(params[:analyzer_session_id])
  end

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
end
