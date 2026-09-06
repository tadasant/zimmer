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
# Each pass computes a **ceiling** — an id it is worth scanning up to — and
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
#     it is a ceiling just past the first PROBE_ROWS rows, which bounds the tick's
#     work while still letting it collect anything expired in that window. As those
#     rows go the window slides forward, so a table drains tick by tick.
#
#     What that does NOT cover, stated rather than implied: more than PROBE_ROWS
#     unexpired rows sitting below EVERY expired row. The window never reaches past
#     them and the pass stalls for as long as that holds. It takes a renumbered
#     sequence or a restore to produce, nothing in Zimmer writes `logs` that way,
#     and the remedy would be a `created_at` index the ceiling could be read off
#     directly. The index this job now has is not that one — see below — so the
#     stall stands as written up in docs/limitations.md.
#
# Each pass then walks DOWNWARD from its ceiling, carrying the last id it took as
# the next batch's ceiling. Restarting each batch at the bottom instead would
# re-walk everything the previous batches already stepped over — quadratic within
# a tick, and in the verbose pass's steady state a scan of every non-verbose row
# between the two windows before reaching the first row it can actually delete.
#
# WHAT THE BATCH SELECTOR IS INDEXED FOR
# --------------------------------------
# `index_logs_on_level_and_id_and_created_at` exists for one query — the verbose
# pass's batch selector, `level = 'verbose' AND created_at < $1 AND id <= $2
# ORDER BY id DESC LIMIT BATCH_SIZE`. All three columns, in that order, because
# what makes it fast is an INDEX-ONLY scan: `level` is the equality, `id` is the
# ordered range the LIMIT stops on, and `created_at` rides along so the cutoff is
# applied without touching a heap this deployment has grown to ~15 GB.
#
# Before it, the planner had nothing that could order by id and drove the query
# off `logs_pkey`, discarding every row that was not an expired verbose one until
# it had collected BATCH_SIZE. That is not a fixed cost, and the reason is the
# paragraph above turned inside out: the walk is linear *within* a tick, but the
# ceiling resets to the top on the *next* tick, and the region just below it is
# precisely what earlier ticks already emptied of verbose rows. The emptied
# prefix only ever grows, so the first batch of every tick got more expensive
# than the last one's — 26 s at 06:00 and 50 s at 15:14 on 2026-09-06, one of
# them finishing 45 seconds before the MCP approval gate's 5-second probe timed
# out and paged #alerts (tadasant/zimmer#329).
#
# It does not end when the backlog does. Once the expired verbose rows are gone
# the selector walks the whole span below the ceiling to find the thin sliver
# that has crossed the window since the last tick, returns fewer than BATCH_SIZE,
# and stops — a full walk every ten minutes, forever. Measured on a 570k-row
# reproduction of that terminal state: 508 ms and 52,752 buffers to return four
# rows, against 0.1 ms and 4 buffers with the index. It was never a backlog that
# would drain its way out of the problem.
#
# `prune` itself is unchanged, and deliberately. The descending walk was already
# the right shape — the index makes it an index-only scan over just the rows the
# pass can delete, so the work per tick is now proportional to what it deletes
# rather than to what it has already deleted. The ceiling machinery stays for the
# reason it was written, which was never speed: it bounds a tick's work and keeps
# the pass making progress on a table whose ids and timestamps disagree.
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

  # How many rows the head probe looks past when the binary search has no answer.
  # Big enough to make progress on a disordered table, small enough that the probe
  # costs a bounded pk scan rather than a walk of a hundred million rows.
  PROBE_ROWS = 25_000

  def perform(budget: SLICE_BUDGET, batch_size: BATCH_SIZE, probe_rows: PROBE_ROWS, now: Time.current)
    deadline = monotonic_now + budget.to_f
    limits = { deadline: deadline, batch_size: batch_size, probe_rows: probe_rows }

    # Oldest first: the general window is a superset of the verbose one, so
    # draining it first means the verbose pass has less to walk over.
    expired = prune(Log.expired(now), cutoff: now - Log::RETENTION, **limits)
    verbose = prune(Log.expired_verbose(now), cutoff: now - Log::VERBOSE_RETENTION, **limits)

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
  #
  # The ceiling walks down with the work: each batch takes the highest ids it can
  # find and the next one starts below them, so a row is stepped over at most once
  # per tick however many batches it takes. See the header for what restarting at
  # the bottom would cost the verbose pass in particular.
  def prune(scope, cutoff:, deadline:, batch_size:, probe_rows:)
    ceiling = ceiling_id(cutoff, probe_rows: probe_rows)
    return 0 if ceiling.nil?

    total = 0

    loop do
      return total if monotonic_now >= deadline

      ids = with_db_retry do
        scope.where(id: ..ceiling).order(id: :desc).limit(batch_size).pluck(:id)
      end
      return total if ids.empty?

      total += with_db_retry { Log.where(id: ids).delete_all }

      ceiling = ids.last - 1
      return total if ids.size < batch_size
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
  def ceiling_id(cutoff, probe_rows:)
    lowest = Log.minimum(:id)
    return nil if lowest.nil?

    # `lowest` is a valid answer from the start once its own row is expired, which
    # is the invariant the search widens: everything at or below `low` is older
    # than the cutoff.
    return probe_ceiling(probe_rows) unless (Log.where(id: lowest).pick(:created_at) || Time.current) < cutoff

    low = lowest
    # Emptied between the two reads — a cascading session delete, say. Nothing to
    # bound, and `low < nil` would raise something DatabaseRetry does not catch.
    high = Log.maximum(:id)
    return nil if high.nil?

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

  # The id of the row just past the first `probe_rows` of them, or the table's
  # largest id when it holds fewer. An index-only scan of at most `probe_rows`
  # entries — cheap enough to run on every tick of a table with nothing to prune,
  # which is the common case that reaches it.
  def probe_ceiling(probe_rows)
    Log.order(:id).offset(probe_rows).limit(1).pick(:id) || Log.maximum(:id)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
