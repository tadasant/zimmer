# frozen_string_literal: true

# The Issues page: the fleet's work backlog joined to what is going on in GitHub
# across the five repos the fleet works.
#
# READ-ONLY, EXCEPT FOR ONE THING THAT IS NOT HERE. The page's single write —
# promoting a queued item to a `priority` session — belongs to
# WorkBacklogPromotionsController, which is where it is for the same reason
# GateDecisionFeedbacksController exists: it is a human's lever over what the
# fleet works on next, and it is drawn at the browser surface rather than on the
# API-key surface an agent session is handed. Read the honest limits of that
# boundary on that controller.
#
# FILTERS COME FROM WorkBacklog::Filters, the same object the REST index and
# `get_work_backlog` use. A second filtering path here would let the page and the
# tools answer "what is on the queue" differently.
#
# GITHUB IS LOADED AT REQUEST TIME and cached for a few minutes — see
# Issues::GithubSnapshot for why there is no mirror table. `#refresh` is the
# button that drops that cache.
class IssuesController < ApplicationController
  # `status` is not offered as a filter: the page shows queued and in-flight
  # items in their own sections, and letting the filter bar set it would make one
  # of the two sections lie.
  FILTER_KEYS = %i[repo surface scope_direction kind estimated_cost pinned].freeze

  # What the filter bar, the chart controls and the pager round-trip between
  # them, so changing the window does not reset the filters and vice versa.
  # WorkBacklogPromotionsController rebuilds this page's URL from the same list —
  # a promote posts from a page and comes back to it — so there is one copy.
  VIEW_KEYS = (FILTER_KEYS + %i[window segment gh_page]).freeze

  # The page.
  def index
    @snapshot = Issues::GithubSnapshot.fetch
    @filters = build_filters
    @board = Issues::Board.new(filters: @filters, snapshot: @snapshot, github_page: params[:gh_page])
    @trend = Issues::Trend.new(
      issues: @board.trend_issues,
      window_days: window_days,
      segment: params[:segment].to_s.presence || Issues::Trend::DEFAULT_SEGMENT,
      direction_for: @board.direction_for
    )
    @query_params = view_params
    # The session a promote just started, when the reader has arrived straight
    # from one. Checked against the table rather than trusted from the URL: the
    # banner is a link, and a link to a session that is not there is worse than
    # no banner.
    # `.to_s` because a nested param (`?promoted_session_id[a]=1`) arrives as
    # ActionController::Parameters, which `find_by` raises on rather than
    # ignoring — a 500 from a hand-edited URL.
    @promoted_session = Session.find_by(id: params[:promoted_session_id].to_s.presence)
  end

  # POST /issues/refresh — drop the cached GitHub read and load it again.
  #
  # A POST rather than a link because it costs ten `gh` calls; a GET would be
  # re-run by every prefetch and every back button.
  def refresh
    Issues::GithubSnapshot.fetch(force: true)
    redirect_to issues_path(view_params), notice: "Reloaded GitHub."
  rescue StandardError => e
    Rails.logger.error("[IssuesController#refresh] #{e.class}: #{e.message}")
    redirect_to issues_path(view_params), alert: "Could not reload GitHub: #{e.message}"
  end

  private

  # A filter the queue cannot honour — an unknown cost, a `pinned` that is
  # neither true nor false — is said out loud rather than silently widened. The
  # API answers 422 for the same input; a page cannot, so it shows the queue
  # unfiltered with the reason on it. Reaching this needs a hand-edited URL:
  # every control on the page is a select.
  def build_filters
    WorkBacklog::Filters.new(filter_params)
  rescue WorkBacklog::Filters::InvalidFilter => e
    flash.now[:alert] = "#{e.message} Showing the queue unfiltered."
    WorkBacklog::Filters.new({})
  end

  def filter_params
    params.permit(*FILTER_KEYS).to_h.compact_blank
  end

  def view_params
    params.permit(*VIEW_KEYS).to_h.compact_blank
  end

  def window_days
    requested = params[:window].to_i
    Issues::GithubSnapshot::WINDOWS.include?(requested) ? requested : Issues::GithubSnapshot::WINDOWS.first
  end
end
