# frozen_string_literal: true

# The index behind `LogRetentionJob#prune`'s verbose batch selector — the query
# that, measured across 2026-09-06, produced the largest `DatabaseChoke` times of
# the day by a factor of 3–10 over everything else (tadasant/zimmer#329):
#
#   SELECT id FROM logs
#   WHERE level = 'verbose' AND created_at < $1 AND id <= $2
#   ORDER BY id DESC LIMIT 5000
#
# Observed at 26–50 seconds a run, once every ten minutes, one of them finishing
# 45 seconds before the MCP approval gate's 5-second reachability probe timed out
# and paged #alerts.
#
# WHY IT IS SLOW, AND WHY THIS SHAPE FIXES IT
#
# `logs` has an index on `level` alone and one on `(session_id, created_at)`, and
# neither can order by `id`. So the planner drives the query off `logs_pkey`,
# walking backwards from the ceiling and discarding every row that is not an
# expired `verbose` one until it has collected 5,000 — and the region just below
# the ceiling is exactly the part earlier ticks have already emptied of verbose
# rows, because the pass deletes downward from the top. That emptied prefix grows
# monotonically as the drain proceeds, so the walk gets longer every tick.
#
# All three columns, and in this order, because that is what makes it an
# INDEX-ONLY scan: `level` is the equality, `id` is the ordered range the LIMIT
# stops on, and `created_at` rides along so the cutoff can be applied without
# touching a heap this deployment has grown to ~15 GB. Measured on a 570k-row
# reproduction of production's steady state (see the PR):
#
#   baseline                   458 ms, 47,644 buffers, 159,557 rows discarded
#   (created_at)               unused — the planner still prefers logs_pkey
#   (level, id)                unused — same; a heap fetch per row costs more
#                              than the pk walk the LIMIT makes it misestimate
#   (level, id, created_at)      2.9 ms, 30 buffers, 0 heap fetches
#
# The two-column candidates are recorded because they are the obvious guesses and
# they do nothing: the win is the index-only scan, not the column list.
#
# `index_logs_on_level` goes at the same time. It is a strict prefix of the new
# index, so Postgres serves everything it served from the composite, and every
# insert into `logs` — one per timeline line, on the hot path of every session —
# has been maintaining both. Dropping it is what makes this change net-neutral on
# the write path rather than a fourth btree on the busiest table in the schema.
# Not a two-deploy dance: an index changes plans, never results, so no old
# container can trip over its absence.
#
# WHY THE BUILD MAY NOT HAPPEN HERE
#
# This migration runs inside `bin/docker-entrypoint`'s `db:prepare`, which
# kamal-proxy health-gates on a 120-second `deploy_timeout`. `CREATE INDEX
# CONCURRENTLY` over a 15 GB table is two heap passes plus two waits for every
# concurrent transaction to drain, and LogRetentionJob itself holds 90-second
# slices — so on the production table it is the deploy's own timeout it would
# most likely spend, and a deploy that fails is strictly worse than a prune that
# is slow.
#
# So the build is only done inline where it is free: an empty or small `logs` —
# every developer machine, CI, a fresh install. Above the threshold, which is
# where both deployed environments sit today, the work belongs to
# `db/post_deploy/20260906160100_build_logs_retention_scan_index.rb`, which
# PostDeployTaskJob starts a couple of minutes after the deploy, off the boot
# path, with a 20-minute lease and an answer for "has it run" on /health.
#
# The cost of that split is a window on a large deployment where this migration
# is recorded as applied and the index does not exist yet. That window is
# minutes, it is visible in `post_deploy_task_runs` rather than silent, and the
# thing it protects is the deploy that carries the fix.
class AddRetentionScanIndexToLogs < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_logs_on_level_and_id_and_created_at"
  SUPERSEDED_INDEX_NAME = "index_logs_on_level"

  # Estimated rows below which building inline is not worth deferring. Two orders
  # of magnitude under the table this is written for, and far enough above a
  # seeded dev database that no laptop takes the deferred path by accident.
  INLINE_BUILD_ROW_LIMIT = 250_000

  def up
    unless build_inline?
      say "logs has ~#{estimated_rows} rows; leaving #{INDEX_NAME} to the post-deploy task", true
      return
    end

    add_index :logs, %i[level id created_at],
              name: INDEX_NAME,
              algorithm: :concurrently,
              if_not_exists: true

    # Strictly after the replacement exists, so there is never an instant with
    # neither. Same ordering the post-deploy task keeps.
    remove_index :logs,
                 name: SUPERSEDED_INDEX_NAME,
                 algorithm: :concurrently,
                 if_exists: true
  end

  def down
    add_index :logs, :level,
              name: SUPERSEDED_INDEX_NAME,
              algorithm: :concurrently,
              if_not_exists: true

    remove_index :logs,
                 name: INDEX_NAME,
                 algorithm: :concurrently,
                 if_exists: true
  end

  private

  def build_inline?
    rows = estimated_rows
    rows.nil? || rows <= INLINE_BUILD_ROW_LIMIT
  end

  # `reltuples`, not `COUNT(*)`: this runs in the boot path, and counting the
  # table is the very cost the split exists to keep out of it. PG14+ reports -1
  # on a table it has never analyzed, which means "unknown", not "empty" — and an
  # unanalyzed `logs` is a fresh database, so unknown takes the inline path.
  def estimated_rows
    value = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT c.reltuples::bigint
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relname = 'logs' AND n.nspname = current_schema()
    SQL

    return nil if value.nil?

    rows = value.to_i
    rows.negative? ? nil : rows
  end
end
