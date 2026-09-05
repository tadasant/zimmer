# frozen_string_literal: true

# Hand-place a queued backlog item, and release it again.
#
# A pin is the human's statement that this item goes exactly here and stays
# there: WorkBacklog::Ranking never re-bands, renumbers or un-pins a pinned item,
# and it is excluded from every peer set so one hand-placement cannot drag future
# appends down with it. `create` sets one at a precedence; `destroy` releases it
# and lets the re-rank put the item back inside the band its cost implies.
#
# WHY THIS IS AN ApplicationController DESCENDANT. The same reason
# WorkBacklogPromotionsController is one, and that controller states it in full:
# Api::V1::WorkBacklogItemsController#pin / #unpin already do this, but
# Api::BaseController authenticates an API key the whole fleet shares — every
# agent session holds it — so posting the page's form there would put the human's
# lever back within reach of the thing it is being kept from. No API key and no
# MCP tool reaches here, and there is no MCP counterpart for these operations on
# purpose.
#
# BE HONEST ABOUT THE STRENGTH OF THAT: ApplicationController authenticates
# nobody. Zimmer's browser surface has no login — the perimeter is the tailnet,
# and agent sessions run inside it — so this boundary means "came in through the
# browser surface", not "a person did it". Read the long version on
# WorkBacklogPromotionsController; the page says the short version where the
# controls are.
#
# NEITHER ACTION REIMPLEMENTS THE RANKING. Both take WorkBacklog::Ranking's
# advisory lock and call the same `pin!` / `unpin!` + `rerank!` pair the REST
# actions call, so a click that races an append or a pull serialises with it.
#
# `issues/_pin` is the form that posts here, on /issues.
class WorkBacklogPinsController < ApplicationController
  include IssuesPageReturn

  before_action :set_item

  # POST /issues/backlog/:id/pin — pin the item at `precedence`.
  def create
    return back(alert: "#{@item.key} is #{@item.status}, so it cannot be pinned.") unless @item.queued?
    return back(alert: "Pinning #{@item.key} needs a precedence.") if params[:precedence].blank?

    WorkBacklog::Ranking.with_lock do
      @item.pin!(precedence: params[:precedence])
      WorkBacklog::Ranking.rerank!
    end

    back(notice: "Pinned #{@item.key} at precedence #{@item.reload.precedence}.")
  rescue ArgumentError, TypeError
    # `pin!` calls `Integer()`, which raises on anything that is not a whole
    # number. The field is a number input, so reaching this takes a hand-edited
    # POST — and a flash is still a better answer than a 500.
    back(alert: "#{params[:precedence].inspect} is not a whole number.")
  rescue ActiveRecord::RecordInvalid => e
    # Out of PRECEDENCE_RANGE: an integer Postgres would reject at the UPDATE.
    # The model catches it first, and nothing has moved.
    back(alert: "Could not pin #{@item.key}: #{e.record&.errors&.full_messages&.to_sentence.presence || e.message}")
  end

  # DELETE /issues/backlog/:id/pin — release the pin and re-rank the item back
  # into its cost band.
  def destroy
    return back(alert: "#{@item.key} is #{@item.status}, so it cannot be unpinned.") unless @item.queued?

    WorkBacklog::Ranking.with_lock do
      @item.unpin!
      WorkBacklog::Ranking.rerank!
    end

    back(notice: "Unpinned #{@item.key}; it is back at precedence #{@item.reload.precedence}.")
  end

  private

  # By row id only, unlike the REST member routes, which also accept an item's
  # key. The forms on the page are rendered from rows the page already loaded, so
  # the id is what they have — and a key resolves to "the queued row for that key,
  # else the most recent one", which is a second thing that could be the wrong row
  # for a control whose whole risk is acting on the wrong row.
  def set_item
    @item = WorkBacklogItem.find_by(id: params[:id].to_s)

    back(alert: "That backlog item no longer exists.") unless @item
  end

  def back(notice: nil, alert: nil)
    back_to_issues(notice: notice, alert: alert)
  end
end
