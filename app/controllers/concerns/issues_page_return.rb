# frozen_string_literal: true

# Every write the Issues page offers comes back to the Issues page.
#
# Rebuilt from the query the form carried rather than from the referrer: each
# form posts the page's own filter and chart state (IssuesController::VIEW_KEYS),
# so the URL is reconstructible and does not depend on a header a browser may
# strip — or on a header a form can be reached from somewhere else with.
#
# `extra` is for the one thing a write wants to say to the page it returns to
# that a flash cannot carry: the layout renders EVERY flash key as its own toast,
# so a `flash[:promoted_session_id]` shows up as a second, contentless popup
# beside the real notice. A query param carries the same thing and the page
# renders one banner from it. Nil values are dropped rather than appearing as an
# empty param.
module IssuesPageReturn
  extend ActiveSupport::Concern

  private

  def back_to_issues(notice: nil, alert: nil, **extra)
    view = params.permit(*IssuesController::VIEW_KEYS).to_h.compact_blank
    view.merge!(extra.compact.transform_keys(&:to_s))
    redirect_to issues_path(view), notice: notice, alert: alert
  end
end
