# frozen_string_literal: true

module Supervisor
  class SessionUncleLinksController < Supervisor::ApplicationController
    # The "uncle" lineage edges, fleet-wide. Useful for the question a
    # per-session hierarchy panel cannot answer: which sessions have been
    # claiming seniority over which others, and through which entry point.
    #
    # Destroy is the point of having this here. An edge is self-declared by the
    # calling session and nothing verifies it, so a mistaken or forged one has to
    # be removable by hand until there is a first-class way to detach it
    # (issue #299). No create or edit: an edge means "this session actually
    # queued or interrupted that one", and hand-authoring one would assert
    # something that never happened.
  end
end
