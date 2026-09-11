# frozen_string_literal: true

module Supervisor
  class SessionUncleLinksController < Supervisor::ApplicationController
    # The "uncle" lineage edges, fleet-wide — which sessions have claimed
    # seniority over which others, and through which entry point.
    #
    # Destroy is the raw form of it. The product surfaces — the × on the session
    # detail page's hierarchy panel, `action_session` → `remove_uncle`, and
    # DELETE /api/v1/sessions/:id/uncle_links/:uncle_id — all go through
    # Sessions::RemoveUncleEdge, which refuses a pair named in the wrong
    # direction and writes the removal into both sessions' timelines. Destroying
    # a row here does neither, so reach for it only when the edge cannot be named
    # from a product surface at all (a truncated hierarchy draws no chip for a
    # senior outside the rendered graph). No create or edit: an edge records that
    # one session actually queued or interrupted another, so hand-authoring one
    # would assert an event that never happened and would go around the
    # acyclicity invariant Sessions::RecordUncleEdge enforces.
  end
end
