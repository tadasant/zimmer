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
  # A screenful of summaries. 1,469 rows at 8-12 KB each is not one page, for a
  # reader or for the wire.
  PER_PAGE = 25

  # Every column EXCEPT `payload`, plus the one thing the list wants out of it.
  #
  # The rows are 11.5 KB on average and all of that weight is the payload, of
  # which the ledger renders exactly one key. Extracting it in Postgres turns a
  # ~290 KB page into a ~3 KB one. Aliased to `list_title` rather than `title`
  # deliberately: `GateDecision#title` reads `payload["title"]`, so a column
  # called `title` on a row loaded without `payload` would be shadowed by the
  # method and raise MissingAttributeError. #show, the REST API and the MCP tools
  # load whole rows and are untouched by this.
  LIST_COLUMNS = (
    (GateDecision.column_names - [ "payload" ]).map { |c| "gate_decisions.#{c}" } +
    [ "gate_decisions.payload->>'title' AS list_title" ]
  ).freeze

  # The ledger, newest first.
  def index
    @filters = build_filters
    scope = @filters.scope.includes(:feedbacks)
    listed = scope.select(LIST_COLUMNS)

    @page = [ params[:page].to_i, 1 ].max
    # One COUNT, and the pager is derived from it. The alternative — fetching one
    # row over the page size to answer "is there a next page" — would be cheaper
    # only if the total were not also on the page, and it is: on a ledger whose
    # job is auditing, "40 decisions match" is most of what the filter bar is for.
    # Two reads of a `payload::text ILIKE` filter over 13 MB is the thing to
    # avoid, not one.
    @total = scope.count
    @has_next_page = @total > @page * PER_PAGE
    @decisions = listed.limit(PER_PAGE).offset((@page - 1) * PER_PAGE).to_a
    # What the pager round-trips, so paging forward does not quietly reset the
    # filters the reader is paging through.
    @filters_query_params = filter_params
    # "No rows match your filter" and "the ledger is empty" are different things
    # to tell someone, and only the second one should mention the importer. Asked
    # here rather than from the view, and only when there is nothing to show.
    @ledger_empty = @total.zero? && !GateDecision.exists?

    load_filter_options
  end

  # One rating, whole.
  def show
    # No `includes(:feedbacks)`: `#chronological` builds a fresh relation off the
    # association and re-queries whatever was preloaded, so the eager load would
    # be a second query rather than a saved one.
    @decision = GateDecision.find(params[:id])
    @payload = GateDecisions::PayloadView.new(@decision.payload)
    @feedbacks = @decision.feedbacks.chronological.to_a
    @related_count, @related = related_decisions(@decision)
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

  # Other ratings of the same artifact — how many there are, and the first few.
  #
  # Not a nicety: rows are append-only, so a re-rate is a NEW row and the earlier
  # reading is still live in the table. 59 rows in the historical corpus are
  # re-rates, and someone reading "why was this held" needs to know a later row
  # un-held it.
  #
  # The count is returned separately from the list because the panel states it,
  # and `list.size + 1` would quietly report "11 times" for an artifact rated
  # fifty — on the one panel whose whole job is saying that a rating was
  # superseded. `select` without `payload` because the panel renders a date, a
  # verdict and an id, and the payloads average 11.5 KB each.
  RELATED_LIMIT = 10

  def related_decisions(decision)
    return [ 0, [] ] if decision.artifact_url.blank?

    scope = GateDecision.for_artifact(decision.artifact_url).where.not(id: decision.id)
    [ scope.count, scope.recent_first.select(:id, :decided_at, :decision).limit(RELATED_LIMIT).to_a ]
  end
end
