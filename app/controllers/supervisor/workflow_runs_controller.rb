# frozen_string_literal: true

module Supervisor
  class WorkflowRunsController < Supervisor::ApplicationController
    # Every workflow run (#18): which workflow a session was started with, fired
    # from which trigger, on what validated input, bound to which trusted
    # identifiers.
    #
    # Index and show only. A WorkflowRun is read-only once written, and its
    # `resolved` identifiers are only worth trusting if nothing but the
    # workflow's #plan ever wrote them — an edit form here would be the one path
    # that could. A run goes away with its session or not at all.
  end
end
