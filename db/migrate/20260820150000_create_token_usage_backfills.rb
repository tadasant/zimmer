# frozen_string_literal: true

# Makes the historical token-usage backfill a thing the app does to itself.
#
# Getting history into the ledger must not require a shell on the production box:
# a deploy is the delivery mechanism for an ops action, not an SSH session. This
# table is what lets a recurring job do the sweep unattended and still answer the
# two questions a one-shot script cannot:
#
#   - has history been backfilled yet, and how far did it get?
#   - is it safe to leave the job on a cron forever?
#
# A row is ONE sweep of the whole transcript corpus. `cursor` is the last
# directory name that was swept, so an interrupted run resumes from where it
# stopped rather than from the beginning — cheap to do because ingestion is
# idempotent on `request_id`, so a re-swept directory writes nothing.
#
# Rows are runs, not a singleton, so a re-scan requested from the Costs page
# leaves the previous run's record intact. At most ONE run may be unfinished at a
# time, which the partial unique index below enforces in the database rather than
# in a read-then-write that two concurrent requests can both win.
# `TokenUsageBackfillJob` works that row, and does nothing at all once every row
# is finished — which is what keeps it a no-op on every deploy after the first.
class CreateTokenUsageBackfills < ActiveRecord::Migration[8.0]
  def change
    create_table :token_usage_backfills do |t|
      # Where the sweep read from. Recorded because a run against a different
      # transcript root covers a different corpus, and a coverage claim without
      # its root is not checkable.
      t.string :transcript_root, null: false

      # Last transcript directory swept, in sort order. NULL means the run has
      # not swept anything yet.
      t.string :cursor

      t.integer :directories_total, default: 0, null: false
      t.integer :directories_done, default: 0, null: false
      t.bigint :files_scanned, default: 0, null: false
      t.bigint :session_rows, default: 0, null: false
      t.bigint :adhoc_rows, default: 0, null: false

      # Why the run exists: "automatic" (the job started it because no sweep had
      # ever completed) or "manual" (someone asked for a re-scan from the Costs
      # page, the REST API, or MCP).
      t.string :trigger, null: false, default: "automatic"

      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :last_ran_at
      t.text :last_error

      t.timestamps
    end

    # The job asks "is there an unfinished run" and "has any run ever finished"
    # on every tick, and the answer is almost always no. Both are index lookups.
    add_index :token_usage_backfills, :finished_at
    add_index :token_usage_backfills, :created_at

    # At most one unfinished run, enforced by the database. Two callers asking
    # for a re-scan at the same moment — a double-clicked button, the button and
    # the MCP action — would otherwise both see no pending run and both create
    # one, and the loser would sit unfinished until the winner completed and then
    # re-sweep the whole corpus from an empty cursor.
    add_index :token_usage_backfills, "(finished_at IS NULL)",
      unique: true, where: "finished_at IS NULL",
      name: "index_token_usage_backfills_one_unfinished"
  end
end
