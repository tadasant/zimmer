# frozen_string_literal: true

# The Gate Decisions page: every rating the PR-merge and issue-work gates have
# made, browsable.
#
# READ-ONLY, EXCEPT FOR ONE THING THAT IS NOT HERE. A GateDecision is
# append-only and written by the gates, so this controller has no create, no
# update and no destroy. The single write the page offers — a human note on a
# rating — belongs to GateDecisionFeedbacksController, which is where it is
# because that is the boundary the ledger's whole design turns on. The form on
# #show posts there.
#
# FILTERS COME FROM GateDecisions::Filters, the same object the REST index and
# `search_gate_decisions` use. A second filtering path here would let the page
# and the tools answer the same question differently, which for a corpus whose
# purpose is calibration would be worse than having no page.
#
# Structured after OutcomesController: a top-level menu-bar page with its own
# routes rather than a nested resource.
class GateDecisionsController < ApplicationController
  # Entries average 11.5 KB, so a page is a screenful of summaries, not a dump.
  # The rows carry their payload either way — jsonb comes back with the row — so
  # this is about what a person can read, and 1,469 rows at 8-12 KB each is not
  # one page.
  PER_PAGE = 25

  # The ledger, newest first.
  def index
    @filters = build_filters
    scope = @filters.scope.includes(:feedbacks)

    @page = [ params[:page].to_i, 1 ].max
    # One row over the page size, so "is there a next page" costs a row rather
    # than a second count over the whole filtered set.
    rows = scope.limit(PER_PAGE + 1).offset((@page - 1) * PER_PAGE).to_a
    @has_next_page = rows.size > PER_PAGE
    @decisions = rows.first(PER_PAGE)
    @total = scope.count
    # What the pager round-trips, so paging forward does not quietly reset the
    # filters the reader is paging through.
    @filters_query_params = filter_params

    load_filter_options
  end

  # One rating, whole.
  def show
    @decision = GateDecision.includes(:feedbacks).find(params[:id])
    @payload = GateDecisions::PayloadView.new(@decision.payload)
    @feedbacks = @decision.feedbacks.chronological.to_a
    @related = related_decisions(@decision)
    @return_params = return_params
  end

  private

  # A filter the ledger cannot honour — an unknown gate, an unparseable date —
  # is said out loud rather than silently widened. The API answers 422 for the
  # same input; a page cannot, so it shows the unfiltered ledger with the reason
  # on it. Reaching this needs a hand-edited URL: every control on the page is a
  # select or a date field.
  def build_filters
    GateDecisions::Filters.new(filter_params)
  rescue GateDecisions::Filters::InvalidFilter => e
    flash.now[:alert] = "#{e.message} Showing the ledger unfiltered."
    GateDecisions::Filters.new({})
  end

  FILTER_KEYS = %i[gate surface decision artifact_query query with_human_feedback from to].freeze

  def filter_params
    params.permit(*FILTER_KEYS).to_h
  end

  def return_params
    filter_params.merge(params[:page].present? ? { "page" => params[:page] } : {})
  end

  # Drawn from the corpus rather than from a constant, because the vocabulary is
  # the gates' and not this app's: a gate that starts writing a new decision word
  # should show up in the filter without a deploy. Cheap — both are index-covered
  # reads over a table in the low thousands.
  def load_filter_options
    @surface_options = GateDecision.distinct.order(:surface).pluck(:surface)
    @decision_options = GateDecision.where.not(decision: nil).distinct.order(:decision).pluck(:decision)
  end

  # Other ratings of the same artifact. Not a nicety: rows are append-only, so a
  # re-rate is a NEW row and the earlier reading is still live in the table. 59
  # rows in the historical corpus are re-rates. Someone reading "why was this
  # held" needs to know a later row un-held it.
  def related_decisions(decision)
    return [] if decision.artifact_url.blank?

    GateDecision.for_artifact(decision.artifact_url).where.not(id: decision.id).recent_first.limit(10).to_a
  end
end
