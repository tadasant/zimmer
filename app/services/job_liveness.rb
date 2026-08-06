# frozen_string_literal: true

# Answers one question about a GoodJob row: is anything still executing it?
#
# WHY THIS EXISTS
# ---------------
# A session records `running_job_id`, and the next job for that session has to decide
# whether the recorded job is still alive (skip — one turn at a time) or dead (supersede
# it — the worker was killed and nobody is coming). Getting that wrong is silent in both
# directions: skip a live-looking corpse and the user's follow-up prompt is lost; supersede
# a job that was merely slow and two agent processes run against one clone.
#
# The check used to be an age heuristic — "an unlocked job older than two minutes is
# abandoned" — which is a guess about how long a healthy queue takes to pick a job up.
# A slow deploy, a busy worker, or a bigger repo moves that goalpost, and the answer
# changes with it. This class replaces the guess with evidence.
#
# WHY NOT `Process.kill(0, pid)`
# ------------------------------
# Zimmer runs the Kamal `web` and `worker` roles as separate containers, each with its own
# PID namespace, and Kamal can spread roles across hosts. A PID recorded by one process is
# not meaningful to another: `Process.kill(0, pid)` answers about the *caller's* namespace,
# so it reports ESRCH for a perfectly healthy worker in another container and — because PIDs
# are recycled — reports "alive" for an unrelated process that happens to have inherited the
# number. Both failure modes are exactly the silent wrongness this check exists to end.
# `SessionRecoveryService`, `CleanupOrphanedSessionsJob` and `SessionsController` all carry
# the same warning for the CLI process they monitor.
#
# So liveness is asked of the database instead, where every container can see the same
# answer. GoodJob already maintains that registry: each capsule inserts a row in
# `good_job_processes`, refreshes it every `GoodJob::Process::STALE_INTERVAL` (30s), and —
# when `advisory_lock_heartbeat` is on, as it is in every Zimmer environment — holds a
# session-scoped Postgres advisory lock on it from the Notifier's retained connection. Kill
# the container and the connection drops, so the lock is released by Postgres itself,
# immediately and without anyone reporting it. `GoodJob::Process.active` is the union of
# those two signals (lock held, or heartbeat refreshed within
# `GoodJob::Process::EXPIRED_INTERVAL`), which makes it a real liveness probe with a
# heartbeat backstop already built in.
#
# NOTE the difference from `GoodJob::Process.exists?(id:)`, which several call sites used
# to ask: that only says a *row* exists. A SIGKILLed worker leaves its row behind until some
# later capsule boots and runs `GoodJob::Process.cleanup`, so `exists?` reports a dead worker
# as alive — potentially forever.
class JobLiveness
  # The bounded fallback, and only that.
  #
  # A job that is unlocked and has never been performed is, as far as GoodJob is concerned,
  # simply queued: it is eligible for pickup and a worker will run it. Age says nothing about
  # whether that is still true, which is why age is no longer the primary signal — every
  # ordinary death (SIGKILL, OOM, an evicted container, a deploy) is caught by the lock-holder
  # probe or by `performed_at` instead.
  #
  # This horizon exists for the residue: a job enqueued onto a queue no live capsule serves,
  # or one whose worker died so uncleanly that neither signal ever materialised. Without it a
  # session could stay wedged forever. It is deliberately far longer than any plausible queue
  # delay, because the two sides of the line are not symmetric — crossing it early double-runs
  # an agent, and the evidence-based checks above already cover the cases where a prompt would
  # otherwise be lost.
  ABANDONED_QUEUED_JOB_AGE = 30.minutes

  # Statuses that mean "something is still going to run this job" — leave it alone.
  LIVE_STATUSES = %i[running queued scheduled].freeze

  # Statuses that mean "nothing is running this job and nothing will" — safe to supersede.
  DEAD_STATUSES = %i[dead_worker interrupted abandoned].freeze

  class << self
    # Classify a GoodJob row.
    #
    # @param job [GoodJob::Job, nil] the row behind a session's `running_job_id`
    # @return [Symbol] one of:
    #   :finished    — already ran to completion (or the row is gone)
    #   :running     — locked by a capsule that is demonstrably alive
    #   :dead_worker — locked by a capsule that is gone: SIGKILL, OOM, evicted container
    #   :scheduled   — deliberately parked for the future (a retry backoff); not yet due
    #   :interrupted — started, then lost its lock; the worker died mid-perform and a later
    #                  capsule's `GoodJob::Process.cleanup` released the lock on its behalf.
    #                  GoodJob re-picks such a row and raises `GoodJob::InterruptError` before
    #                  `perform` runs, so superseding it cannot double-run the payload.
    #   :queued      — enqueued, not yet picked up; a worker will get to it
    #   :abandoned   — queued past ABANDONED_QUEUED_JOB_AGE; the bounded fallback
    def status(job)
      return :finished if job.nil? || job.finished_at.present?

      if job.locked_by_id.present?
        lock_holder_alive?(job.locked_by_id) ? :running : :dead_worker
      elsif job.scheduled_at.present? && job.scheduled_at > Time.current
        # Checked ahead of performed_at deliberately. GoodJob nils performed_at when it
        # re-enqueues a job for a retry backoff, so the two should never both apply — and
        # if they ever did, waiting for a future scheduled_at costs latency while calling
        # it dead costs a second agent process on the same clone.
        :scheduled
      elsif job.performed_at.present?
        :interrupted
      elsif job.created_at.present? && job.created_at < ABANDONED_QUEUED_JOB_AGE.ago
        :abandoned
      else
        :queued
      end
    end

    # @return [Boolean] true when the job is still being executed, or still will be
    def alive?(job)
      LIVE_STATUSES.include?(status(job))
    end

    # @return [Boolean] true when it is safe for a newer job to take this one's place
    def superseded?(job)
      DEAD_STATUSES.include?(status(job))
    end

    # Is the capsule holding this lock still running — anywhere in the deployment?
    #
    # `GoodJob::Process.active` is advisory-lock-first with a heartbeat fallback; see the
    # class comment for why that is the right question and `exists?` is not.
    #
    # @param process_id [String, nil] a `good_job_processes` UUID (`GoodJob::Job#locked_by_id`)
    # @return [Boolean]
    def lock_holder_alive?(process_id)
      return false if process_id.blank?

      GoodJob::Process.active.exists?(id: process_id)
    end

    # Human-readable reason for a supersede decision, for the session log.
    # @param status [Symbol] a value returned by {.status}
    # @return [String]
    def explain(status)
      case status
      when :dead_worker then "its worker is gone (lock holder is no longer an active GoodJob process)"
      when :interrupted then "it started and then lost its lock (worker died mid-execution)"
      when :abandoned   then "it sat queued and unclaimed for over #{ABANDONED_QUEUED_JOB_AGE.inspect}"
      when :finished    then "it already finished"
      when :running     then "it is locked by a live worker"
      when :queued      then "it is queued and waiting for a worker"
      when :scheduled   then "it is scheduled to run in the future"
      else "status #{status}"
      end
    end
  end
end
