# frozen_string_literal: true

# `index_logs_on_session_id` is fully redundant with the leading column of
# `index_logs_on_session_id_and_created_at`: Postgres serves an equality or range
# on `session_id` alone from the composite, and that includes the ON DELETE
# CASCADE from `sessions`. Every write to `logs` — one per timeline line, on the
# hot path of every session — has been maintaining both.
#
# On staging's measured table (124M rows, 5,031 MB of indexes) dropping it is
# gigabytes back on the volume whose exhaustion is tadasant/zimmer#437, and one
# less index to update on the insert path.
#
# CONCURRENTLY, because a plain DROP INDEX takes an ACCESS EXCLUSIVE lock on
# `logs` and this migration runs during `db:prepare` at container boot, which
# kamal-proxy health-gates. Dropping an index is not a schema change old
# containers can trip over: it changes plans, never results, so this needs no
# two-deploy dance.
#
# Deliberately NOT paired with a new `created_at` index. LogRetentionJob deletes
# by primary-key range precisely so that shipping retention does not also mean
# building an index over a hundred million rows inside a health-gated deploy.
class DropRedundantSessionIdIndexOnLogs < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    remove_index :logs,
      :session_id,
      name: "index_logs_on_session_id",
      algorithm: :concurrently,
      if_exists: true
  end
end
