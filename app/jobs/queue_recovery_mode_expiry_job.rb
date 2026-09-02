# frozen_string_literal: true

# The TTL backstop for QueueRecoveryMode: lifts a halt whose window has elapsed,
# so an operator who walked away cannot leave production frozen indefinitely.
#
# Queue placement is the whole point. `pollers`, `triggers`, `inference` and `default` are
# exactly the queues recovery mode halts, so a job that lives on any of them would
# be paused by the state it exists to clear — the deadlock version of a watchdog.
# `agents` is the one queue recovery mode deliberately leaves running, so this runs
# on it. It is not an agent job, and it is the only exception to that queue's
# meaning; the alternative (a dedicated queue) would cost a scheduler thread and
# therefore a database connection, which ConnectionBudget budgets and Terraform
# enforces against the cluster's plan.
#
# `agents` can still starve: eight long-running sessions occupy every thread, and
# that is precisely the runaway-session incident recovery mode exists for. So this
# is not the only backstop — ApplicationController#reconcile_queue_recovery_mode
# performs the same check from the web process, which needs no worker thread. The
# two are independent on purpose.
class QueueRecoveryModeExpiryJob < ApplicationJob
  queue_as :agents

  # Cheap and idempotent, but there is no value in stacking cron ticks on the queue
  # that is holding agent sessions.
  good_job_control_concurrency_with(
    key: -> { "queue_recovery_mode_expiry" },
    total_limit: 1
  )

  def perform
    QueueRecoveryMode.expire_if_due!
  end
end
