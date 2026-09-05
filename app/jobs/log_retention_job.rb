# frozen_string_literal: true

# Enforces Log's retention policy, so the `logs` table is bounded by time rather
# than by total fleet activity (tadasant/zimmer#437).
#
# WHY THIS EXISTS
# ---------------
# `logs` had no retention in any deployment. It is written on the hot path of
# every session, so it grew forever: on staging it reached 124M rows / 24 GB of a
# 31 GB Postgres volume, the disk filled, backends could not write
# `pg_internal.init`, the checkpointer hit ENOSPC and PANICked, and Postgres went
# into a crash-recovery loop. An unbounded log table on a full disk takes the
# whole database down, not just logging.
#
# The policy itself lives on Log (`Log::RETENTION`, `Log::VERBOSE_RETENTION`) —
# the model owns what its rows are worth; this job owns how to delete them
# without hurting the database.
#
# SAFE ON A TABLE THAT IS ALREADY ENORMOUS
# ----------------------------------------
# The first deployment to run this meets a table with years of rows in it and no
# maintenance window, so a single `DELETE FROM logs WHERE created_at < …` is not
# on the table: it would hold one transaction over a hundred million rows, bloat
# WAL, and block on locks for as long as it took. Instead:
#
#   * Work is chunked (BATCH_SIZE rows per statement, one transaction each), so no
#     lock is held long and each chunk is durable on its own.
#   * Each tick stops at SLICE_BUDGET whether or not the backlog is drained, so the
#     job returns its worker thread on time and the next cron tick resumes. A
#     deployment starting from 124M rows converges over hours instead of needing a
#     human with a shell to drain it first.
#   * It is a singleton (SingletonSweep), so a slow tick cannot stack copies that
#     would contend on the same rows.
#
# Deleting does not shrink the files it frees — Postgres marks the space reusable
# and the table stops growing, but the 19 GB already allocated comes back only
# with `VACUUM FULL` or `pg_repack`. That is a one-time, per-environment
# reclamation, written up in docs/operate/background-jobs.md.
#
# WHY IT DELETES BY PRIMARY KEY
# -----------------------------
# There is no index on `logs.created_at`, and adding one is not free here: it is
# built during `db:prepare` at container boot, which kamal-proxy health-gates on a
# `deploy_timeout` of 120 seconds, so a CREATE INDEX over 124M rows would fail the
# very deploy that ships the fix.
#
# So each pass computes a **ceiling** — an id it is worth scanning up to — and
# drives the delete off `id <= ceiling`, which is a primary-key range scan. The
# cutoff stays a predicate on the delete itself, so the ceiling only ever decides
# how much of the table one tick looks at. It can never widen what is deleted, and
# a row inside its retention window is never deleted whatever the ceiling says.
#
# The ceiling comes from one of two places:
#
#   The binary search, when the lowest-id row is already expired. ~31 single-row
#     index lookups find the id below which every row is older than the cutoff.
#     This is the steady state, because ids and timestamps are ordered together: a
#     sequence-backed pk and a `created_at` of `now()` make that true to within a
#     transaction's duration, seconds against windows measured in days.
#
#   The head probe, otherwise. Normally "the oldest row is inside the window" means
#     there is nothing to do — but it also describes a table whose ids and
#     timestamps disagree, where a single recent row with a low id would otherwise
#     hide every expired row above it FOREVER. Retention silently never running
#     again is the bug this job exists to fix, so the fallback is not "give up":
#     it is a ceiling at the PROBE_ROWS-th row, which bounds the tick's work while
#     still letting it collect anything expired near the head. The window slides
#     forward as rows go, so a disordered table converges tick by tick instead of
#     stalling.
class LogRetentionJob < ApplicationJob
  include DatabaseRetry
  include SingletonSweep

  # `maintenance`, with the other bulk sweeps, and deliberately not `default` or
  # `pollers`: this holds its thread for up to SLICE_BUDGET, and the latency-
  # sensitive pollers must not queue behind it.
  queue_as :maintenance

  # Rows per statement. Big enough that the per-statement overhead is noise on a
  # 100M-row drain, small enough that one chunk's locks are held for milliseconds.
  BATCH_SIZE = 5_000

  # How long one tick may work. Comfortably inside the 10-minute cron cadence, so
  # a slice always finishes and hands its thread back before the next tick.
  SLICE_BUDGET = 90.seconds

  # How far into the table the head probe looks when the binary search has no
  # answer. Big enough to make progress on a disordered table, small enough that
  # the probe costs a bounded pk scan rather than a walk of a hundred million rows.
  PROBE_ROWS = 25_000

  def perform(budget: SLICE_BUDGET, batch_size: BATCH_SIZE, now: Time.current)
    deadline = monotonic_now + budget.to_f

    # Oldest first: the general window is a superset of the verbose one, so
    # draining it first means the verbose pass has less to walk over.
    expired = prune(Log.expired(now), cutoff: now - Log::RETENTION, deadline: deadline, batch_size: batch_size)
    verbose = prune(Log.expired_verbose(now), cutoff: now - Log::VERBOSE_RETENTION, deadline: deadline, batch_size: batch_size)

    total = expired + verbose
    if total > 0
      Rails.logger.info(
        "[LogRetentionJob] deleted #{total} expired log row(s): #{expired} older than " \
        "#{Log::RETENTION.inspect}, #{verbose} verbose row(s) older than #{Log::VERBOSE_RETENTION.inspect}"
      )
    end

    { expired: expired, verbose: verbose, total: total }
  end

  private

  # Delete `scope` in chunks until it is empty or the slice budget is spent.
  #
  # `scope` already carries the cutoff predicate; `cutoff` is passed separately
  # only so the primary-key ceiling can be computed for the same instant.
  def prune(scope, cutoff:, deadline:, batch_size:)
    ceiling = ceiling_id(cutoff)
    return 0 if ceiling.nil?

    bounded = scope.where(id: ..ceiling)
    total = 0

    loop do
      return total if monotonic_now >= deadline

      deleted = with_db_retry do
        Log.where(id: bounded.order(:id).limit(batch_size).select(:id)).delete_all
      end

      total += deleted
      return total if deleted < batch_size
    end
  end

  # The id one pass should scan up to, or nil when the table is empty.
  #
  # Binary search over the id space — not over row positions. Ids go sparse as rows
  # are pruned, which is fine: the search narrows on values, and a ceiling that
  # names no existing row is still a correct `<=` bound. Each step is
  # `ORDER BY id DESC LIMIT 1` over a pk range, which Postgres answers from the
  # index in constant time, so a 124M-row table costs ~31 cheap queries.
  #
  # The search needs its lower bound to be expired to start, and when it is not,
  # `probe_ceiling` takes over rather than the pass giving up. See the header for
  # why "the oldest row is recent" must not be read as "there is nothing to do".
  def ceiling_id(cutoff)
    lowest = Log.minimum(:id)
    return nil if lowest.nil?

    # `lowest` is a valid answer from the start once its own row is expired, which
    # is the invariant the search widens: everything at or below `low` is older
    # than the cutoff.
    return probe_ceiling unless (Log.where(id: lowest).pick(:created_at) || Time.current) < cutoff

    low = lowest
    high = Log.maximum(:id)

    while low < high
      mid = low + ((high - low + 1) / 2)
      newest = Log.where(id: ..mid).order(id: :desc).limit(1).pick(:created_at)

      if newest.nil? || newest < cutoff
        low = mid
      else
        high = mid - 1
      end
    end

    low
  end

  # The id of the PROBE_ROWS-th row, or the table's largest id when it holds
  # fewer. An index-only scan of at most PROBE_ROWS entries — cheap enough to run
  # on every tick of a table with nothing to prune, which is the common case that
  # reaches it.
  def probe_ceiling
    Log.order(:id).offset(PROBE_ROWS).limit(1).pick(:id) || Log.maximum(:id)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
