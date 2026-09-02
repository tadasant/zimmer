# frozen_string_literal: true

module Supervisor
  class WorkBacklogItemsController < Supervisor::ApplicationController
    # The work backlog, fleet-wide: every item the issue work gate has queued,
    # what became of it, and the whole payload each one carried.
    #
    # Index and show only. Every write to the queue — append, pull, pin, remove —
    # runs under WorkBacklog::Ranking's lock and re-ranks afterwards, through the
    # REST controller or the MCP tools. A row edited here would skip both.
  end
end
