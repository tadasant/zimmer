# frozen_string_literal: true

module Supervisor
  class SessionUncleLinksController < Supervisor::ApplicationController
    # The "uncle" lineage edges, fleet-wide — which sessions have claimed
    # seniority over which others, and through which entry point.
    #
    # Destroy is the point of having this here. An edge is self-declared by the
    # calling session and nothing verifies it, so a mistaken or forged one needs
    # a way out until there is a first-class detach (issue #299). No create or
    # edit: an edge records that one session actually queued or interrupted
    # another, so hand-authoring one would assert an event that never happened
    # and would go around the acyclicity invariant Sessions::RecordUncleEdge
    # enforces.
  end
end
