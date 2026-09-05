# frozen_string_literal: true

# A wall-clock ceiling on how long one run of a sweep may hold its scheduler
# thread.
#
# **What goes wrong without it.** `maintenance` has two threads
# (ConnectionBudget#good_job_queue_threads) and they serve two kinds of work at
# once: recurring filesystem sweeps, and the per-archive stream of
# DeferredCloneCleanupJob rows — one per archived session, arriving at whatever
# rate the fleet archives. A sweep bounded only by a batch *count* can hold one
# of those two threads for tens of minutes (OrphanCloneFilesystemCleanupJob's
# BATCH_LIMIT of 20 directories, each tearing down Docker Compose bounded at
# DockerComposeCleanupService::COMPOSE_DOWN_TIMEOUT, is 40 minutes of entirely
# correct work), and while it does the lane runs at half capacity for everything
# else. Two such sweeps at once take it to zero. On 2026-09-05 the lane sat 124
# DeferredCloneCleanupJob rows deep with a head of line two hours old and rising,
# and paged.
#
# **Why stopping early costs nothing.** These sweeps are level-triggered, which
# is the same property SingletonSweep relies on to drop a tick outright: each run
# reads the current state and acts on whatever is due, so work a run does not
# reach is simply done by the next one. A budget therefore trades *latency* on
# the backstop — which already runs hourly or six-hourly — for throughput on the
# lane, and loses no work.
#
# **Why not re-enqueue a continuation instead.** Both sweeps that use this
# include SingletonSweep, whose `total_limit: 1` is enforced at enqueue: a
# continuation would be refused while the cron copy is still unfinished, which is
# the hazard SingletonSweep's own comment names. The next scheduled tick is the
# continuation.
#
# Monotonic, so a clock adjustment mid-sweep cannot make a budget expire early or
# never. The check goes at the TOP of each iteration, so the true bound is the
# budget plus whatever one more unit of work costs.
module SweepBudget
  extend ActiveSupport::Concern

  # Open a budget for this run. Call once, at the top of `perform`.
  #
  # @param seconds [Numeric] how long the whole run may take
  def start_sweep_budget(seconds)
    @sweep_deadline = monotonic_now + seconds.to_f
  end

  # Whether the budget opened by `start_sweep_budget` has run out. False when no
  # budget was opened, so a caller that never opened one is never cut short.
  def sweep_budget_spent?
    return false if @sweep_deadline.nil?

    monotonic_now >= @sweep_deadline
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
