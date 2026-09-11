# frozen_string_literal: true

# Detaching a lineage edge recorded in error.
#
# Uncle edges are written as a side effect of a queue or an interrupt, from an
# `acting_session_id` the caller declares about itself (see
# `Sessions::RecordUncleEdge`). This is the only endpoint that unwrites one, and
# there is deliberately no companion that writes one: creation belongs to the
# recorder, which is where the acyclicity invariant lives.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::UncleLinksController < Api::BaseController
  # DELETE /api/v1/sessions/:session_id/uncle_links/:uncle_id
  #
  # `:session_id` is the JUNIOR — the session whose hierarchy grew when the edge
  # was written — and `:uncle_id` the senior being detached. Both are in the path
  # because direction is the whole content of an uncle edge: the same pair of
  # sessions can be joined either way round (`RecordUncleEdge` inverts an edge
  # when the junior turns round and queues its senior), and a request that named
  # only the pair would be ambiguous about which claim it meant.
  #
  # Optional body param:
  #   - acting_session_id: the agent session driving this call, recorded on both
  #     timelines as the actor. Self-declared, like everywhere else on this API —
  #     one key is shared by the whole fleet, so a request establishes a caller
  #     but not a session. Omitting it says so rather than inventing an actor.
  #
  # 204 on success, 404 when no such edge exists — never a silent success, since
  # an operator who believes a wrong edge is gone while it still widens two
  # sessions' context is worse off than one who got an error.
  def destroy
    session = Session.locate!(params[:session_id])

    Sessions::RemoveUncleEdge.call(
      junior: session,
      uncle_session_id: params[:uncle_id],
      actor: actor_phrase,
      source: "api_v1:sessions.uncle_links.destroy"
    )

    head :no_content
  rescue Sessions::RemoveUncleEdge::NotFound => e
    render_api_error("Not found", e.message, status: :not_found)
  rescue Sessions::RemoveUncleEdge::Error => e
    render_api_error("Validation failed", e.message, status: :unprocessable_entity)
  end

  private

  # The mirror of `Mcp::Tools::ActionSession#removal_actor_phrase`. "An undeclared
  # API caller" is still an answer to "a human or an agent?", because a human
  # detaching an edge does it from the hierarchy panel, not with curl.
  def actor_phrase
    declared = params[:acting_session_id].to_s.strip[/\A\d+\z/]
    return "an undeclared REST API caller" if declared.nil?

    "session ##{declared} via the REST API"
  end
end
