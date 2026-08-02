# frozen_string_literal: true

module Supervisor
  class TimelineEventsController < Supervisor::ApplicationController
    # The Human Timeline, fleet-wide: every message Zimmer established was
    # authored by a named human. Browsing it answers "what did a human actually
    # ask for, and where" across sessions, which the per-session panel cannot.
    #
    # No new or edit: TimelineEvent refuses update precisely so a record of what
    # a human said cannot be rewritten after the fact, and hand-authoring one
    # would be forging an author. Destroy stays, because a misattributed event
    # is worse than a missing one — see the append-only guard on the model.
  end
end
