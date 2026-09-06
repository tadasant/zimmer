# frozen_string_literal: true

# Builds `index_logs_on_level_and_id_and_created_at` on a `logs` table too large
# to index inside the deploy, and drops the `index_logs_on_level` it supersedes.
#
# THE POINT OF THIS FILE: the index itself is
# `db/migrate/20260906160000_add_retention_scan_index_to_logs.rb`, and on an empty
# or small table that migration builds it inline — which covers every developer
# machine, CI and a fresh install. Neither deployed environment is one: production
# holds ~3.3M rows and staging's table is the 124M-row one the retention policy
# was written against, still draining. Migrations run
# inside `bin/docker-entrypoint`'s `db:prepare`, kamal-proxy health-gates that on
# a 120-second `deploy_timeout`, and `CREATE INDEX CONCURRENTLY` over a ~15 GB
# table is two heap passes plus two waits for concurrent transactions to
# drain — one of which is LogRetentionJob's own 90-second slice. Building it
# there risks spending the deploy_timeout of the very deploy that carries the
# fix, and a deploy that fails is strictly worse than a prune that is slow.
#
# Off the boot path it is ordinary work: PostDeployTaskJob starts it a couple of
# minutes after the deploy, holds a 20-minute lease, and answers "has it run" in
# `post_deploy_task_runs` — on /health, in `GET /api/v1/health`, from
# `get_system_health`, at /supervisor/post_deploy_task_runs.
#
# IDEMPOTENCY has three parts, because a half-applied `CREATE INDEX CONCURRENTLY`
# leaves state a plain `IF NOT EXISTS` reads wrong:
#
#   * An advisory lock, so two builders can never overlap however the ledger's
#     lease is reaped. Without it a lease reaped mid-build lets a second worker
#     find the first one's in-progress index and treat it as wreckage.
#   * A failed concurrent build leaves the index present and `indisvalid = false`
#     — it is never used by the planner and never repaired on its own, and
#     `IF NOT EXISTS` would skip right over it. So an invalid index is dropped
#     first, under the lock that proves nobody is building it.
#   * The drop of the superseded index runs only after the new one exists and is
#     valid, so no failure ordering leaves `logs` with neither.
class BuildLogsRetentionScanIndex < PostDeployTask
  # Spelled out rather than read from the migration class: a task file has to
  # keep loading long after the migration that motivated it has been squashed
  # away, exactly as a migration names its own columns.
  INDEX_NAME = "index_logs_on_level_and_id_and_created_at"
  SUPERSEDED_INDEX_NAME = "index_logs_on_level"
  INDEX_COLUMNS = "(level, id, created_at)"

  # Any stable 64-bit constant. Only this task takes it.
  ADVISORY_LOCK_KEY = 82_060_906_160_100

  def up
    return CONTINUE unless try_lock

    begin
      drop_invalid_index
      create_index
      drop_superseded_index
    ensure
      unlock
    end

    checkpoint!(**index_sizes)
    nil
  end

  private

  def connection = ActiveRecord::Base.connection

  def try_lock
    locked = connection.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    return true if ActiveModel::Type::Boolean.new.cast(locked)

    logger.info("[#{self.class.name}] another builder holds the lock; will resume")
    false
  end

  def unlock
    connection.select_value("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
  rescue StandardError => e
    # Never mask the real error from `up`. The lock is session-scoped and the
    # connection goes back to the pool, so the worst case is one held lock until
    # that connection is recycled — which the next tick's `try_lock` reports.
    logger.warn("[#{self.class.name}] could not release the advisory lock: #{e.message}")
  end

  # Wreckage from an interrupted build: present in `pg_index`, invisible to the
  # planner, and skipped by `IF NOT EXISTS` forever.
  def drop_invalid_index
    return unless invalid_index?

    logger.warn("[#{self.class.name}] dropping an invalid #{INDEX_NAME} left by an earlier attempt")
    connection.execute("DROP INDEX CONCURRENTLY IF EXISTS #{connection.quote_table_name(INDEX_NAME)}")
  end

  def create_index
    return if valid_index?

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    connection.execute(<<~SQL.squish)
      CREATE INDEX CONCURRENTLY IF NOT EXISTS #{connection.quote_table_name(INDEX_NAME)}
      ON logs #{INDEX_COLUMNS}
    SQL
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)

    # A build that fails leaves the statement raising, so reaching here with an
    # invalid index means `IF NOT EXISTS` skipped over wreckage the drop above
    # should have taken. Say so rather than reporting success.
    raise "#{INDEX_NAME} is still invalid after #{elapsed}s" if invalid_index?

    checkpoint!(build_seconds: elapsed)
    logger.info("[#{self.class.name}] built #{INDEX_NAME} in #{elapsed}s")
  end

  # `index_logs_on_level` is a strict prefix of the new index, so every plan it
  # served is served by the composite — and `logs` takes one insert per timeline
  # line on the hot path of every session, so carrying both would make this
  # change a fourth btree on the busiest table in the schema instead of a
  # like-for-like replacement. Strictly after the replacement is valid.
  def drop_superseded_index
    return unless valid_index?

    connection.execute("DROP INDEX CONCURRENTLY IF EXISTS #{connection.quote_table_name(SUPERSEDED_INDEX_NAME)}")
  end

  def invalid_index? = index_state == false

  def valid_index? = index_state == true

  # true / false / nil for valid / invalid / absent.
  def index_state
    connection.select_value(<<~SQL.squish)
      SELECT i.indisvalid
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_index i ON i.indexrelid = c.oid
      WHERE c.relname = #{connection.quote(INDEX_NAME)} AND n.nspname = current_schema()
    SQL
  end

  # Counters a human reads on the health panel to see what the deploy bought.
  def index_sizes
    row = connection.select_one(<<~SQL.squish) || {}
      SELECT pg_size_pretty(pg_relation_size(#{connection.quote(INDEX_NAME)}::regclass)) AS built,
             pg_size_pretty(pg_indexes_size('logs'::regclass)) AS logs_indexes_total
    SQL

    { index_size: row["built"], logs_index_total: row["logs_indexes_total"] }
  rescue StandardError
    {}
  end
end
