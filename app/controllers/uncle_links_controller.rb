# frozen_string_literal: true

# The browser half of detaching a mistaken uncle edge (#299) — the × on an "also
# senior" chip in the session-detail hierarchy panel.
#
# Destroy only. A human has no way to WRITE an uncle edge from the browser and
# this deliberately does not give them one: the web UI controllers have no
# `acting_session_id` at all, which is how "a human is never an uncle" is
# guaranteed structurally rather than by a flag somebody has to set correctly
# (see UncleEdgeEntryPointsTest). Removal is the other direction and carries none
# of that risk — the worst a wrong removal does is narrow a graph, and the write
# path can put the edge back.
#
# Note on authorization: this app is a single-user internal tool, as the rest of
# the controllers here say at more length. There is no per-user check to make.
class UncleLinksController < ApplicationController
  include TurboFlash

  # DELETE /sessions/:session_id/uncle_links/:uncle_id
  #
  # `:session_id` is the junior and `:uncle_id` the senior, the same way round as
  # the REST twin — the chip is rendered on one row per session in the hierarchy,
  # so the junior is the row's session and not necessarily the page's.
  #
  # `viewer_id` is presentation only: which session's panel to repaint. The
  # model's `after_destroy_commit` already broadcasts to every session in the
  # graph, but that is a job, and a click owes its clicker a response that has
  # already happened rather than one that is coming.
  def destroy
    @session = Session.locate!(params[:session_id])

    Sessions::RemoveUncleEdge.call(
      junior: @session,
      uncle_session_id: params[:uncle_id],
      actor: "a human in the web UI",
      source: "web_ui:session_hierarchy.detach"
    )

    respond_with_panel(notice: "Removed ##{params[:uncle_id]} as an additional senior of ##{@session.id}.")
  rescue Sessions::RemoveUncleEdge::Error => e
    # Both failure kinds land here: on this surface the operator gets the same
    # sentence either way, and the sentence is the service's, which is the one
    # that knows whether the pair is joined in the other direction.
    respond_with_panel(alert: e.message)
  end

  private

  # The panel repainted is the VIEWER's, not the junior's. A row on session #7's
  # page can carry #9's chip, and replacing #9's provenance div would target an
  # id that is not on the page — leaving the operator looking at the edge they
  # just removed.
  def viewer
    @viewer ||= Session.locate(params[:viewer_id]) || @session
  end

  # The repaint plus the flash, through the shared TurboFlash pair. The flash is
  # not decoration on the failure path: a refused removal re-renders a panel that
  # looks exactly as it did, so the message is the only thing that tells the
  # operator why the edge is still there.
  def respond_with_panel(notice: nil, alert: nil)
    panel = turbo_stream.replace(
      "session_#{viewer.id}_provenance",
      partial: "sessions/session_hierarchy",
      locals: { agent_session: viewer }
    )

    respond_with_flash(location: viewer, notice: notice, alert: alert, streams: [ panel ])
  end
end
