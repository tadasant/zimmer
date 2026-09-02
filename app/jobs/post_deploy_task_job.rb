# frozen_string_literal: true

# Runs the one-time post-deploy tasks in `db/post_deploy/`.
#
# This is the delivery mechanism for an ops action, in place of "and then someone
# runs `rake …` on prod". It is on cron rather than in `bin/docker-entrypoint` or
# a Kamal hook on purpose: a task that is slow, or that raises, must not extend
# or wedge the deploy, and the entrypoint is a place where either would. The
# price is that a task starts within a couple of minutes of the deploy rather
# than during it, which is the right trade for work that is by construction not
# on the request path.
#
# Cheap in the steady state: once every task has succeeded, a tick is one indexed
# `SELECT` per task file plus a directory listing.
#
# QUEUE PLACEMENT — `default`, deliberately not `pollers`, for the same reason
# TokenUsageBackfillJob gives: this can hold its thread for minutes, and
# `pollers` has three threads shared by every latency-sensitive singleton poller.
class PostDeployTaskJob < ApplicationJob
  # One pass at a time across the fleet. The ledger row's conditional claim is
  # what actually makes double-running a task impossible; this stops cron from
  # stacking passes that would each find every row already claimed.
  include SingletonSweep

  queue_as :default

  # A post-deploy task may be the step that makes a new queue topology safe for
  # rows written by the previous release. Put the runner ahead of ordinary
  # default work so that an old backlog cannot prevent its own migration.
  queue_with_priority(-100)

  # How long one pass may hold its worker thread. Well under the two-minute cron
  # interval, so a pass has finished and returned the thread before the next tick
  # and the singleton guard above has nothing to reject in normal running.
  SLICE_BUDGET = 90.seconds

  def perform(budget: SLICE_BUDGET)
    PostDeployTask::Runner.new(budget: budget).call
  end
end
