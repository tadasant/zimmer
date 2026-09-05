# frozen_string_literal: true

# Take a queued backlog item off the queue, by judgement, with a reason.
#
# THE DISCRETIONARY REMOVAL, NOT THE MECHANICAL ONE. WorkBacklog::Pull already
# removes items an agent can observe are dead — `issue_closed`,
# `issue_has_open_pr`, `session_already_working`, `trust_failed`, drawn from a
# fixed vocabulary rather than typed — but only when the groomer reaches them, so
# an item near the bottom of the queue with a closed issue can sit there for a
# long time. This is the other kind: free text, a human's call, available on any
# queued row the page is showing.
#
# The row is not deleted. `remove!` sets `status: removed` with the reason and
# who, and the item stays as history — the queue's record of what was decided
# against is as useful as its record of what was done.
#
# WHY THIS IS AN ApplicationController DESCENDANT, and how weak that boundary
# actually is: exactly as WorkBacklogPromotionsController states it. The REST
# action exists, but Api::BaseController authenticates an API key the whole fleet
# shares, so a form posting there would put the lever back within reach of the
# thing it is being kept from. There is no MCP counterpart, on purpose. What this
# does NOT establish is that a person did it — Zimmer's browser surface
# authenticates nobody.
#
# ACTING ON THE WRONG ROW IS THE RISK WORTH NAMING. A mis-wired remove control
# silently drops queued work, and unlike promote there is no new session to
# notice. Four things answer it: the form carries the row id and nothing else
# identifies the item, the confirmation names the key it is about to remove, the
# flash names the key that was actually removed, and WorkBacklogQueuedWrite
# re-reads that row under the ranking lock — so a pull that starts the item while
# the reader is deciding is seen, rather than overwritten with `removed`.
#
# `issues/_remove` is the form that posts here, on /issues.
class WorkBacklogRemovalsController < ApplicationController
  include IssuesPageReturn
  include WorkBacklogQueuedWrite

  # Who the removal is attributed to. `remove!` records the same string the REST
  # action defaults to: this came in through the browser surface, which is the
  # closest thing to a person Zimmer can currently tell.
  REMOVED_BY = "human"

  # POST /issues/backlog/:id/remove — body: reason (required, free text).
  def create
    return back_to_issues(alert: "Removing that item needs a reason.") if params[:reason].blank?

    write_to_queued_item("removed") do |item|
      item.remove!(reason: params[:reason].to_s, by: REMOVED_BY)
      WorkBacklog::Ranking.rerank!
      "Removed #{item.key} from the queue."
    end
  end
end
