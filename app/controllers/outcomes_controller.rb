# frozen_string_literal: true

# The Outcomes view: a ledger of archived transcripts and what an analysis said
# about them, a per-transcript flamegraph drilldown, and a separate summary-stats
# surface.
#
# Nothing here analyzes anything on read. #index and #stats are pure reads; an
# analysis only ever starts from #analyze or #analyze_all, both of which are
# POSTs behind a button a human pressed.
#
# Structured after QuotasController: a top-level menu-bar page with its own
# routes rather than a nested resource.
class OutcomesController < ApplicationController
  before_action :load_filters, only: [ :index, :stats, :analyze_all ]

  # The ledger. Archived sessions only — see OutcomeAnalyses::LedgerQuery for
  # why, and for how the analysis columns ride along without loading a tree.
  def index
    query = OutcomeAnalyses::LedgerQuery.new(@filters)
    @counts = query.counts
    @page = [ params[:page].to_i, 1 ].max
    # One row over the page size, so "is there a next page" costs a row rather
    # than a second COUNT over the whole filtered set.
    rows = query.rows.limit(PER_PAGE + 1).offset((@page - 1) * PER_PAGE).to_a
    @has_next_page = rows.size > PER_PAGE
    @rows = rows.first(PER_PAGE)

    load_filter_options
    # What every button on this page round-trips, so a click lands the user back
    # on the ledger they clicked from rather than on a reset one.
    @return_params = @filters.to_query_params.merge(@page > 1 ? { page: @page } : {})
    @batches = OutcomeAnalysisBatch.recent.limit(5).to_a
    @setup_warnings = OutcomeAnalyses::Config.unavailable_reasons
  end

  # The flamegraph drilldown for one analyzed session.
  def show
    @session = find_session!(params[:id])
    @analysis = OutcomeAnalysis.current.find_by(session_id: @session.id)

    if @analysis.nil?
      redirect_to outcomes_path, alert: "Session ##{@session.id} has not been analyzed yet."
      return
    end

    @previous_analyses = OutcomeAnalysis.superseded
      .without_tree
      .where(session_id: @session.id)
      .order(analyzed_at: :desc)
      .limit(10)
    @flame = OutcomeAnalyses::Flamegraph.new(@analysis.root)
  end

  # The separate summary-stats surface. Deliberately not a panel on the ledger:
  # the ledger answers "what happened to this transcript", this answers "what is
  # happening across all of them", and mixing the two makes both worse.
  def stats
    @stats = OutcomeAnalyses::Stats.new(filters: @filters, grouping: params[:group_by])
    load_filter_options
  end

  # POST — spawn one analysis session for one archived transcript.
  def analyze
    session = find_session!(params[:id])
    analysis_session = OutcomeAnalyses::SpawnAnalysisSession.call(session: session)

    redirect_back_to_ledger(
      notice: "Analyzing session ##{session.id}. Spawned session ##{analysis_session.id} — it saves the result back here when it finishes."
    )
  rescue OutcomeAnalyses::SpawnAnalysisSession::Error, ActiveRecord::RecordInvalid, AgentRootsConfig::AgentRootNotFoundError => e
    redirect_back_to_ledger(alert: "Could not start the analysis: #{e.message}")
  end

  # POST — enqueue an analysis for every session matching the CURRENT filters,
  # running at most `concurrency` at a time.
  def analyze_all
    batch = OutcomeAnalyses::StartBatch.call(filters: @filters, concurrency: params[:concurrency])

    notice = "Queued #{batch.total_count} #{'analysis'.pluralize(batch.total_count)} at #{batch.concurrency} at a time."
    notice += " That is well above what the spot gate will let through — watch the batch and stop it if it misbehaves." if batch.advisory_concurrency?
    redirect_back_to_ledger(notice: notice)
  rescue OutcomeAnalyses::StartBatch::NothingToAnalyze => e
    redirect_back_to_ledger(alert: e.message)
  end

  # POST — stop a running batch. Queued items are canceled; analyses already in
  # flight are left to finish (see OutcomeAnalyses::CancelBatch).
  def cancel_batch
    batch = OutcomeAnalysisBatch.find(params[:id])
    canceled = OutcomeAnalyses::CancelBatch.call(batch)

    redirect_back_to_ledger(
      notice: "Stopped batch ##{batch.id}. #{canceled} queued #{'analysis'.pluralize(canceled)} canceled; " \
              "#{batch.reload.running_count} already in flight will finish."
    )
  end

  private

  PER_PAGE = 50

  def load_filters
    @filters = OutcomeAnalyses::LedgerFilters.from_params(params)
  end

  def load_filter_options
    @agent_root_options = AgentRootsConfig.all.map(&:name).sort
    @runtime_options = RuntimeRegistry.registered_runtimes
    @model_options = OutcomeAnalyses::LedgerQuery.model_options
  end

  def find_session!(identifier)
    session = if identifier.to_s.match?(/\A\d+\z/)
      Session.find_by(id: identifier.to_i)
    else
      Session.find_by(slug: identifier.to_s)
    end
    raise ActiveRecord::RecordNotFound, "No session #{identifier.inspect}" unless session

    session
  end

  # Every write action lands the user back on the ledger they clicked from, with
  # their filters and page intact — losing a filter set on every Analyze click
  # would make the batch workflow unusable.
  def redirect_back_to_ledger(**flash_args)
    redirect_to outcomes_path(return_params), **flash_args
  end

  def return_params
    OutcomeAnalyses::LedgerFilters.from_params(params).to_query_params.merge(
      params[:page].present? ? { page: params[:page] } : {}
    )
  end
end
