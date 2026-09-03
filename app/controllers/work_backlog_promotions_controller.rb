# frozen_string_literal: true

# The ONE write the Issues page offers: promote a queued backlog item to a
# `priority` session, right now.
#
# WHY THIS CONTROLLER EXISTS AT ALL, RATHER THAN THE PAGE POSTING TO THE API.
# Api::V1::WorkBacklogItemsController#start_now already does this, and says in
# its own comments why it has no MCP counterpart: hand-placing an item, removing
# one by judgement and promoting one are the human's levers over what the fleet
# works on next, and a queue read by an unattended job is exactly the place an
# agent must not be able to pull them. But Api::BaseController authenticates an
# API key the whole fleet shares — every agent session holds it — so posting the
# page's form there would put the lever back within reach of the thing it is
# being kept from. This is an ApplicationController descendant: no API key
# reaches it and no MCP tool writes here.
#
# BE HONEST ABOUT THE STRENGTH OF THAT. ApplicationController performs no
# authentication at all. Zimmer's browser surface authenticates nobody — the
# perimeter is the tailnet, and agent sessions run inside it. This boundary rules
# out a promote over the shared API key, on the REST and MCP surfaces a session is
# actually offered; it does not rule out an agent that goes looking for this
# route, and CSRF enforcement — which would make it fetch a token off a Zimmer
# page first — is a speed bump, not a boundary. "A human clicked this" needs a way
# to tell a person from an agent at the web surface, which is the agent-login
# primitive Zimmer does not have yet (#371, #220). Until then this means "came in
# through the browser surface", which is weaker, and the button should be read
# that way. The UI says so too.
#
# `issues/_promote` is the form that posts here, on /issues. It is the only thing
# that does.
class WorkBacklogPromotionsController < ApplicationController
  # POST /issues/backlog/:id/promote
  def create
    item = WorkBacklogItem.find(params[:id])

    result = WorkBacklog::Start.call(
      item: item,
      scheduling_class: SessionGenesis::PRIORITY,
      # No parent session: a promote comes from a browser, not from a groomer.
      # `web_ui` is where it came from, which is all genesis claims.
      genesis: SessionGenesis::WEB_UI
    )

    back(notice: "Promoted #{result.item.key} to a priority session.", session: result.session)
  rescue ActiveRecord::RecordNotFound
    back(alert: "That backlog item no longer exists.")
  rescue WorkBacklog::Start::NotQueued => e
    # The ordinary race: two tabs, or a groomer's pull between the page render
    # and the click. Nothing was spawned, and saying so is the whole fix.
    back(alert: "Nothing was started — #{e.message}.")
  rescue AgentRootsConfig::AgentRootNotFoundError => e
    back(alert: "Cannot spawn a session: #{e.message}")
  end

  private

  # Back to the page the button was on, rebuilt from the query the form carried
  # rather than from the referrer — the promote form posts the page's own filter
  # and chart state (see `issues/_promote`), so the URL is reconstructible and
  # does not depend on a header a browser may strip.
  #
  # The new session's id rides in that URL rather than in the flash. The layout
  # renders EVERY flash key as its own toast, so a `flash[:promoted_session_id]`
  # shows up as a second, contentless "Promoted Session / 2" popup beside the
  # real notice. A query param carries the same thing and the page renders one
  # banner from it, with a link.
  def back(notice: nil, alert: nil, session: nil)
    view = params.permit(*IssuesController::VIEW_KEYS).to_h.compact_blank
    view["promoted_session_id"] = session.id if session
    redirect_to issues_path(view), notice: notice, alert: alert
  end
end
