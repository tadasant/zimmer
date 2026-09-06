# frozen_string_literal: true

# `logs.session_id` is an `integer` in every environment that exists: the column
# predates this repo, it came across in the first `db/schema.rb` dump, and every
# database since was built by loading that dump. But `20251112023554_create_logs`
# declares `t.references :session`, which is `bigint`, so a from-zero
# `db:migrate` builds a table that no deployed database matches.
#
# Nothing noticed because CI only ever loaded the schema. `db:schema:verify` is
# the check that sees it, and this migration is what makes the two paths agree.
#
# The alignment goes toward `integer`, the type production already has, so this
# is a no-op on every existing database. The other direction — widening the
# column to `bigint` — is a full table rewrite under an ACCESS EXCLUSIVE lock on
# the highest-write table in the app, taken during `db:prepare` at container
# boot. That is a deliberate change with its own risk, not a side effect of
# wiring up a check.
class AlignLogsSessionIdTypeForMigrationReplay < ActiveRecord::Migration[8.0]
  def up
    return if session_id_sql_type == "integer"

    change_column :logs, :session_id, :integer, null: false
  end

  def down
    # Schema-loaded environments already own the `integer` column, and widening
    # it here would rewrite the table on a rollback. Nothing to undo.
  end

  private

  def session_id_sql_type
    connection.columns(:logs).find { |column| column.name == "session_id" }&.sql_type
  end
end
