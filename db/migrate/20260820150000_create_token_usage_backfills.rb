# frozen_string_literal: true

# Makes the historical token-usage backfill a thing the app does to itself.
#
# The ledger tables landed with a `rake token_usage:backfill` task, which meant
# the only way to get history into them was for a human to open a shell on the
# production box. That is exactly the kind of operational step Zimmer is supposed
# not to have: a deploy is the delivery mechanism for ops actions, not an SSH
# session. This table is what lets a recurring job do the sweep unattended and
# still answer the two questions a one-shot script cannot:
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
# leaves the previous run's record intact. `TokenUsageBackfillJob` only ever
# works the newest unfinished row, and does nothing at all once every row is
# finished — which is what keeps it a no-op on every deploy after the first.
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
  end
end
