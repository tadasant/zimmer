# frozen_string_literal: true

module Supervisor
  class SessionStatusSummariesController < Supervisor::ApplicationController
    # The cached Status blurbs, fleet-wide. Useful for two questions a
    # per-session panel cannot answer: which sessions have generations wedged in
    # `pending` (a fork that died without ever reaching pause or fail), and which
    # keep failing for the same reason.
    #
    # No create: a summary exists because a session asked for one. Editing is
    # limited to `state` — see the dashboard for why the text and the line counts
    # are not hand-editable. Destroy is allowed: deleting a row is how you make
    # the next status change regenerate from scratch.
  end
end
