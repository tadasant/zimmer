# frozen_string_literal: true

require "test_helper"

# The space-in-use estimate against real TOAST, which needs VACUUM and so cannot run in a
# transaction. It owns one scratch table and drops it.
class HealthMonitorDatabaseSizeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  TABLE = "zz_toast_probe"

  setup do
    sql "DROP TABLE IF EXISTS #{TABLE}"
    # Autovacuum off, so the only vacuums are the ones this test runs.
    sql "CREATE TABLE #{TABLE} (id int, body text) WITH (autovacuum_enabled = false, toast.autovacuum_enabled = false)"
    sql "ALTER TABLE #{TABLE} ALTER body SET STORAGE EXTERNAL"
    sql "INSERT INTO #{TABLE} SELECT n, repeat('x', 100000) FROM generate_series(1, 60) n"
  end

  teardown { sql "DROP TABLE IF EXISTS #{TABLE}" }

  def sql(statement) = ActiveRecord::Base.connection.execute(statement)

  def reusable
    sql "SELECT pg_stat_force_next_flush()"
    sql "SELECT 1"
    _total, tables = HealthMonitorService.new.send(:read_database_sizes)
    tables.find { |row| row["name"] == TABLE }["reusable_bytes"].to_i
  end

  def toast_bytes
    ActiveRecord::Base.connection.select_value("SELECT pg_relation_size(reltoastrelid) FROM pg_class WHERE relname = '#{TABLE}'").to_i
  end

  test "follows deletes, and reuse, once a vacuum has set the count" do
    assert_equal 0, reusable, "never vacuumed: no estimate"
    sql "VACUUM #{TABLE}"
    assert_operator reusable, :<, toast_bytes * 0.1

    sql "DELETE FROM #{TABLE} WHERE id <= 30"
    assert_in_delta toast_bytes * 0.5, reusable, toast_bytes * 0.1
    sql "VACUUM #{TABLE}"
    size = toast_bytes

    sql "INSERT INTO #{TABLE} SELECT n, repeat('y', 100000) FROM generate_series(61, 75) n"
    assert_in_delta size, toast_bytes, size * 0.05, "the insert reuses freed space"
    assert_in_delta size * 0.25, reusable, size * 0.1
  end

  test "lost statistics read as no reusable space, not as an empty table, until a vacuum" do
    sql "VACUUM #{TABLE}"
    oid = ActiveRecord::Base.connection.select_value("SELECT reltoastrelid FROM pg_class WHERE relname = '#{TABLE}'")
    # Flushed first, or the counts still pending here would be added back after the reset.
    sql "SELECT pg_stat_force_next_flush()"
    sql "SELECT 1"
    sql "SELECT pg_stat_reset_single_table_counters(#{oid})"
    sql "INSERT INTO #{TABLE} VALUES (99, repeat('z', 100000))"

    assert_equal 0, reusable
    live = ActiveRecord::Base.connection.select_value("SELECT pg_stat_get_live_tuples(#{oid})")
    assert_operator live, :>, 0, "the count has started again"
    assert_operator live * 2048, :<, toast_bytes * 0.1, "and no longer describes the table"

    sql "VACUUM #{TABLE}"
    assert_operator reusable, :<, toast_bytes * 0.1
  end
end
