# frozen_string_literal: true

# The ledger for one-time post-deploy tasks — Zimmer's answer to `after_party`.
#
# A one-time operational step ("sweep this column", "delete these orphans",
# "re-key that cache") is not a migration: it needs application code, it can take
# an hour, and a schema migration that does either wedges the deploy. Historically
# it became a rake task, which made a deploy insufficient — somebody had to open a
# shell on the production box, which this deployment deliberately does not offer.
#
# So a task is a file in `db/post_deploy/`, and this table is the record of which
# ones have run. One row per task version, created the first time the runner sees
# the file and never deleted, so "has this run, when, and did it work" is a query
# rather than a guess.
#
# The row is also the mutex. `PostDeployTask::Runner` claims a task with a
# conditional UPDATE against `status`, so two containers coming up at once cannot
# both run the same task: one wins the row, the other reads zero affected rows and
# moves on. `locked_at` carries a lease so a worker killed mid-task does not leave
# the task claimed forever.
class CreatePostDeployTaskRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :post_deploy_task_runs do |t|
      # The timestamp prefix of the task file, e.g. "20260830100500". Unique, and
      # the identity of the task: renaming the class does not re-run it, and two
      # files claiming the same version is a bug the database refuses.
      t.string :version, null: false

      # The class name, for humans reading the dashboard.
      t.string :name, null: false

      # pending → running → succeeded, or → failed. See PostDeployTaskRun.
      t.string :status, null: false, default: "pending"

      # Two counters, because they answer different questions. `attempts` is how
      # many times a runner has claimed the row — a task sliced across an hour
      # legitimately claims dozens of times and none of them is a problem.
      # `failures` is how many times in a row it has *raised* (or had its lease
      # reclaimed after killing its worker), and that is what the retry backoff
      # is indexed by. A slice that asks to be resumed resets it.
      t.integer :attempts, null: false, default: 0
      t.integer :failures, null: false, default: 0

      # Task-owned resume state. A task too slow for one slice stashes where it
      # got to here and returns :continue; the next tick hands it back.
      t.jsonb :cursor, null: false, default: {}

      # Task-owned counters, rendered verbatim on the health panel. Whatever the
      # task wants a human to be able to see about what it did.
      t.jsonb :stats, null: false, default: {}

      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :last_ran_at

      # When a failed task becomes eligible again. NULL on a failed row means the
      # retries are spent and it will not be retried without someone asking.
      t.datetime :next_attempt_at

      t.text :last_error
      t.datetime :last_error_at

      # The lease. Set when a runner claims the row, cleared when it lets go.
      t.datetime :locked_at
      t.string :locked_by

      t.timestamps
    end

    add_index :post_deploy_task_runs, :version, unique: true

    # The runner's every-tick question is "is anything not yet succeeded", and
    # once the backlog is empty the answer is no. An index makes that free.
    add_index :post_deploy_task_runs, :status
  end
end
