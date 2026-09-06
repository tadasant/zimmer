# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260906160000_add_retention_scan_index_to_logs")

# The guard, which is the only interesting thing in this migration.
#
# Building the index is one `add_index`. Deciding *not* to build it is what keeps
# a 15 GB `logs` from spending kamal-proxy's 120-second `deploy_timeout` inside
# `db:prepare` — and a guard that silently stopped guarding would put that back
# without failing anything else.
class AddRetentionScanIndexToLogsTest < ActiveSupport::TestCase
  include LogsRetentionIndexSchema

  # DDL, and `CREATE INDEX CONCURRENTLY` cannot run inside a transaction.
  self.use_transactional_tests = false

  setup do
    @migration = AddRetentionScanIndexToLogs.new
    rewind_logs_indexes!
  end

  teardown { restore_logs_indexes! }

  test "builds the index inline on a table small enough to afford it" do
    migrate_up

    assert_equal %w[level id created_at], logs_index_columns(INDEX_NAME)
    assert_not_includes logs_index_names, SUPERSEDED_INDEX_NAME,
      "the superseded index goes at the same time, strictly after the replacement exists"
  end

  test "declines to build inline on a table the deploy could not afford" do
    @migration.stub(:estimated_rows, AddRetentionScanIndexToLogs::INLINE_BUILD_ROW_LIMIT + 1) do
      migrate_up
    end

    assert_not_includes logs_index_names, INDEX_NAME,
      "a large logs table leaves the build to the post-deploy task, off the boot path"
    assert_includes logs_index_names, SUPERSEDED_INDEX_NAME,
      "and nothing is dropped either, because nothing replaced it yet"
  end

  test "treats a never-analyzed table as small rather than as large" do
    # PG14+ reports `reltuples = -1` on a table it has never analyzed. That is a
    # fresh database, which is exactly where the inline build belongs — reading
    # it as a row count would make -1 the smallest table there is by accident,
    # and reading it as "unknown, so defer" would leave a new install with no
    # index and no worker to run the task.
    @migration.stub(:estimated_rows, nil) { migrate_up }

    assert_includes logs_index_names, INDEX_NAME
  end

  test "down restores the superseded index before removing the replacement" do
    migrate_up
    migrate_down

    assert_includes logs_index_names, SUPERSEDED_INDEX_NAME
    assert_not_includes logs_index_names, INDEX_NAME
  end

  private

  def migrate_up = ActiveRecord::Migration.suppress_messages { @migration.up }

  def migrate_down = ActiveRecord::Migration.suppress_messages { @migration.down }
end
