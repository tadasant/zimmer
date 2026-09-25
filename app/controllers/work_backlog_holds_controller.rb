# frozen_string_literal: true

# Hold a stranded backlog row for a human decision, from the Issues page.
#
# The browser twin of the `hold_work_backlog_item_for_decision` MCP tool and the
# REST `hold` action: all three go through WorkBacklog::Hold, so they refuse the
# same rows. Unlike promote, pin and remove this is not a human-only lever — an
# agent may hold a row too — so there is no boundary to re-draw here; the form
# exists so a person reading Stranded can record the same outcome an agent can.
#
# `issues/_hold` is the form that posts here, on /issues.
class WorkBacklogHoldsController < ApplicationController
  include IssuesPageReturn

  # Who the hold is attributed to, as the other /issues writes attribute theirs.
  HELD_BY = "human"

  # POST /issues/backlog/:id/hold — body: reason (required, free text).
  def create
    item = WorkBacklogItem.find_by(id: params[:id].to_s)
    return back_to_issues(alert: "That backlog item no longer exists.") unless item

    WorkBacklog::Hold.call(item: item, reason: params[:reason], by: HELD_BY)
    back_to_issues(notice: "Held #{item.key} for a decision until #{item.held_until.to_date.iso8601}.")
  rescue WorkBacklog::Hold::Refused => e
    back_to_issues(alert: e.message)
  end
end
