# frozen_string_literal: true

# Puts `logs` back into the shape a deployment has *before*
# `20260906160000_add_retention_scan_index_to_logs` lands, and restores it after.
#
# Both the migration and the post-deploy task it defers to are DDL over the
# schema every other test shares, so they can only be exercised for real by a
# test that mutates it and puts it back. `CREATE INDEX CONCURRENTLY` also cannot
# run inside a transaction, which is why every test that includes this sets
# `use_transactional_tests = false` — nothing here is undone by a rollback.
module LogsRetentionIndexSchema
  INDEX_NAME = "index_logs_on_level_and_id_and_created_at"
  SUPERSEDED_INDEX_NAME = "index_logs_on_level"

  def rewind_logs_indexes!
    drop_index(INDEX_NAME)
    connection.execute("CREATE INDEX IF NOT EXISTS #{SUPERSEDED_INDEX_NAME} ON logs (level)")
  end

  def restore_logs_indexes!
    connection.execute("CREATE INDEX IF NOT EXISTS #{INDEX_NAME} ON logs (level, id, created_at)")
    drop_index(SUPERSEDED_INDEX_NAME)
  end

  def logs_index_names
    connection.indexes(:logs).map(&:name)
  end

  # true / false / nil for valid / invalid / absent — the same reading the task
  # makes, so a test can tell "built" from "left behind by a failed build".
  def logs_index_validity(name)
    connection.select_value(<<~SQL.squish)
      SELECT i.indisvalid
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_index i ON i.indexrelid = c.oid
      WHERE c.relname = #{connection.quote(name)} AND n.nspname = current_schema()
    SQL
  end

  def logs_index_columns(name)
    connection.indexes(:logs).find { |index| index.name == name }&.columns
  end

  private

  def connection = ActiveRecord::Base.connection

  def drop_index(name)
    connection.execute("DROP INDEX IF EXISTS #{connection.quote_table_name(name)}")
  end
end
