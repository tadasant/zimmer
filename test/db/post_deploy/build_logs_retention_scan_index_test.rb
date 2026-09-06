# frozen_string_literal: true

require "test_helper"

# The build half of the fix in tadasant/zimmer#329.
#
# The index itself is a migration; this task exists because on production's
# `logs` the migration declines to build it in `db:prepare`, inside kamal-proxy's
# 120-second `deploy_timeout`. What is worth testing is therefore not "does
# `CREATE INDEX` work" but the three things that make an unattended, retried
# build safe: it does not overlap itself, it repairs the wreckage an interrupted
# `CREATE INDEX CONCURRENTLY` leaves behind, and it never drops the index it
# supersedes before the replacement is actually valid.
class BuildLogsRetentionScanIndexTest < ActiveSupport::TestCase
  include LogsRetentionIndexSchema

  # DDL, and `CREATE INDEX CONCURRENTLY` cannot run inside a transaction.
  self.use_transactional_tests = false

  setup do
    @entry = PostDeployTask::Registry.find("20260906160100")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
    rewind_logs_indexes!
  end

  teardown do
    restore_logs_indexes!
    PostDeployTaskRun.where(name: @entry.task_name).delete_all
  end

  test "builds the retention scan index and drops the one it supersedes" do
    run, outcome = run_task

    assert_nil outcome, "the build finishes in one slice rather than asking to be resumed"
    assert_equal true, logs_index_validity(INDEX_NAME), "the index must be built and valid"
    assert_equal %w[level id created_at], logs_index_columns(INDEX_NAME),
      "column order is the whole point — it is what makes the batch selector an index-only scan"
    assert_not_includes logs_index_names, SUPERSEDED_INDEX_NAME,
      "index_logs_on_level is a strict prefix of the new index and must not be maintained alongside it"
    assert run.stats["index_size"].present?, "the health panel needs something to show for the build"
  end

  test "a second run is a no-op rather than a rebuild" do
    run_task
    built_at = index_relfilenode(INDEX_NAME)

    _run, outcome = run_task

    assert_nil outcome
    assert_equal true, logs_index_validity(INDEX_NAME)
    assert_equal built_at, index_relfilenode(INDEX_NAME),
      "a re-run must not rebuild the index it already built"
  end

  test "replaces an index left invalid by an interrupted build" do
    # An interrupted CREATE INDEX CONCURRENTLY leaves the index present and
    # `indisvalid = false`: never used by the planner, never repaired on its own,
    # and skipped forever by a plain IF NOT EXISTS. Reported here the way
    # Postgres reports it, because the alternative is flipping a catalog bit.
    leave_invalid_index!
    wreckage = index_relfilenode(INDEX_NAME)

    assert_equal false, logs_index_validity(INDEX_NAME),
      "the setup has to leave a genuinely invalid index or this test proves nothing"

    _run, outcome = run_task

    assert_nil outcome
    assert_equal true, logs_index_validity(INDEX_NAME),
      "a plain IF NOT EXISTS would have skipped the wreckage and left it invalid forever"
    assert_not_equal wreckage, index_relfilenode(INDEX_NAME), "the index must be rebuilt, not adopted"
    assert_not_includes logs_index_names, SUPERSEDED_INDEX_NAME
  end

  test "yields instead of building while another connection holds the advisory lock" do
    other = ActiveRecord::Base.connection_pool.checkout

    begin
      assert other.select_value("SELECT pg_try_advisory_lock(#{@task_class::ADVISORY_LOCK_KEY})"),
        "the other connection must actually get the lock for this test to mean anything"

      _run, outcome = run_task

      assert_equal PostDeployTask::CONTINUE, outcome,
        "a contended build asks to be resumed rather than reporting success"
      assert_nil logs_index_validity(INDEX_NAME), "nothing may be built while another builder holds the lock"
      assert_includes logs_index_names, SUPERSEDED_INDEX_NAME,
        "and nothing may be dropped either — the replacement does not exist yet"
    ensure
      other.select_value("SELECT pg_advisory_unlock(#{@task_class::ADVISORY_LOCK_KEY})")
      ActiveRecord::Base.connection_pool.checkin(other)
    end
  end

  test "leaves the superseded index in place when the replacement did not get built" do
    task = build_task

    # `create_index` silently doing nothing is the shape a future edit could
    # introduce; the ordering has to survive it.
    task.stub(:create_index, nil) do
      task.up
    end

    assert_nil logs_index_validity(INDEX_NAME)
    assert_includes logs_index_names, SUPERSEDED_INDEX_NAME,
      "no failure ordering may leave logs with neither index"
  end

  private

  def connection = ActiveRecord::Base.connection

  def real_index_state = logs_index_validity(INDEX_NAME)

  # A real interrupted `CREATE INDEX CONCURRENTLY`, not a stubbed reading of one.
  # CONCURRENTLY commits the catalog entry first and then waits for every
  # transaction holding a lock that conflicts with SHARE to finish, so an open
  # transaction holding ROW EXCLUSIVE on `logs` — what any writer holds — plus a
  # short `statement_timeout` cancels it in that wait, leaving exactly the
  # `indisvalid = false` index a killed container leaves.
  #
  # The lock, rather than a plain `SELECT`: under READ COMMITTED a finished
  # `SELECT` releases its snapshot and holds only ACCESS SHARE, which conflicts
  # with nothing CONCURRENTLY waits on, so it does not block the build at all.
  def leave_invalid_index!
    blocker = ActiveRecord::Base.connection_pool.checkout

    begin
      blocker.execute("BEGIN")
      blocker.execute("LOCK TABLE logs IN ROW EXCLUSIVE MODE")

      connection.execute("SET statement_timeout = '1s'")
      assert_raises(ActiveRecord::QueryCanceled) do
        connection.execute("CREATE INDEX CONCURRENTLY #{INDEX_NAME} ON logs (level, id, created_at)")
      end
    ensure
      connection.execute("RESET statement_timeout")
      begin
        blocker.execute("ROLLBACK")
      rescue StandardError
        nil
      end
      ActiveRecord::Base.connection_pool.checkin(blocker)
    end
  end

  def index_relfilenode(name)
    connection.select_value("SELECT relfilenode FROM pg_class WHERE relname = #{connection.quote(name)}")
  end

  def build_task
    run = PostDeployTaskRun.create!(
      version: "#{@entry.version}-#{SecureRandom.hex(4)}",
      name: @entry.task_name,
      status: "pending"
    )
    assert run.claim!(owner: "test"), "the ledger row must be claimable"
    @task_class.new(run: run, logger: Rails.logger)
  end

  def run_task
    task = build_task
    outcome = task.up
    [ task.run.reload, outcome ]
  end
end
