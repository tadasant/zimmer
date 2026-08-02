# frozen_string_literal: true

module Supervisor
  class HumanMessagesController < Supervisor::ApplicationController
    # Every message Zimmer established was authored by a named human, fleet-wide.
    # Browsing them answers "what did a human actually ask for, and where" across
    # sessions, which a per-session panel cannot.
    #
    # No new or edit: HumanMessage refuses update precisely so a record of what a
    # human said cannot be rewritten after the fact, and hand-authoring one would
    # be forging an author. Destroy stays, because a misattributed record is
    # worse than a missing one.
  end
end
