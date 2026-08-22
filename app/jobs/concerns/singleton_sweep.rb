# Keeps a recurring, argument-less sweep to one outstanding copy.
#
# **What goes wrong without it.** GoodJob's cron enqueues on schedule whether or
# not the previous tick has run yet, so a sweep's arrival rate is fixed and
# cannot fall under load. When its queue is congested the copies accumulate, and
# because they all recompute the same due-set they do redundant work that
# contends with itself — several HeartbeatSweepJob copies taking `SELECT … FOR
# UPDATE` on the same rows serialize on each other, so each one runs slower than
# a single sweep would have. The queue gets slower, which piles up more copies.
# That loop is what turned a 30-second cadence into 39 ready copies during the
# 2026-08-22 backlog incident.
#
# **Why one copy is enough.** These sweeps are level-triggered: each run reads
# the current state and acts on whatever is due, so the work a skipped tick would
# have done is simply done by the next one. Nothing is lost by refusing a tick —
# only the redundancy is.
#
# **Scope.** Recurring jobs whose `perform` takes no arguments. A sweep that
# takes arguments re-enqueues itself with them to chain retries (see
# RefreshRuntimeAuthTokensJob), and a class-wide key would block that chain
# behind the cron copy. `test/jobs/recurring_sweep_concurrency_test.rb` holds the
# line: it walks the cron table and fails if an argument-less sweep is
# unguarded.
#
# This is the idiom every `pollers` job already uses, written once. That queue
# stayed flat at 2 ready jobs through the same incident that put 125 on
# `default`, which is the difference this closes.
module SingletonSweep
  extend ActiveSupport::Concern

  included do
    # `total_limit`, so at most one copy exists unfinished — queued OR running.
    # `enqueue_limit` alone would not count the running copy and would let a
    # second one queue behind a sweep that is still going.
    good_job_control_concurrency_with(
      key: -> { self.class.name },
      total_limit: 1
    )
  end
end
