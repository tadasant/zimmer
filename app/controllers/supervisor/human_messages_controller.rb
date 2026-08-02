# frozen_string_literal: true

module Supervisor
  class HumanMessagesController < Supervisor::ApplicationController
    # Every message Zimmer established was authored by a named human, fleet-wide.
    # Browsing them answers "what did a human actually ask for, and where" across
    # sessions, which a per-session panel cannot.
    #
    # Index and show only. HumanMessage refuses update AND direct destroy, so a
    # record of what a human said cannot be rewritten or quietly removed after
    # the fact — that unforgeability is the whole reason the record is worth
    # anything. Hand-authoring one would forge an author; a record goes away
    # with its session or not at all.
  end
end
