# frozen_string_literal: true

# Base class for a **one-time post-deploy task** — Zimmer's equivalent of the
# `after_party` gem, built on what this app already has rather than bolted on.
#
# WHAT THIS IS FOR
#
# The one-off operational step that a deploy implies and a schema migration
# cannot carry: sweep a newly added column, delete a corpus of orphaned rows,
# re-key a cache, fix data an old bug wrote. Historically each of those became a
# `rake` task, which made the deploy insufficient — somebody had to open a shell
# on the production box to finish the rollout. This deployment deliberately does
# not offer that shell (AGENTS.md, "No production box access"), so the step has to
# ship *with* the deploy. That is what this is.
#
# AUTHORING
#
# One file per task in `db/post_deploy/`, named like a migration:
#
#   db/post_deploy/20260830100500_prune_orphaned_widgets.rb
#
#     class PruneOrphanedWidgets < PostDeployTask
#       def up
#         Widget.where(owner_id: nil).delete_all
#       end
#     end
#
# The timestamp is the identity: it is what the ledger records, so renaming the
# class does not re-run the task. Nothing registers the file — `Registry` finds
# it. Generate one with `bin/rails generate post_deploy_task prune_orphaned_widgets`.
#
# WHAT RUNS IT
#
# `PostDeployTaskJob`, on GoodJob cron, in the worker. Not the entrypoint and not
# a Kamal hook: a task that is slow, or that raises, must not extend or wedge the
# deploy. The cost of that choice is that a task starts within a couple of
# minutes of the deploy rather than during it — which is the right trade for work
# that is, by construction, not on the request path.
#
# LONG-RUNNING WORK
#
# This mechanism is for the hour-long case as well as the ten-millisecond one.
# A task gets a time budget (`PostDeployTaskJob::SLICE_BUDGET`) and hands its
# worker thread back when the budget runs out; returning `CONTINUE` from `up`
# asks to be resumed on the next tick, with `cursor` carrying whatever the task
# needs to pick up where it stopped. `sweep` below is that pattern packaged, and
# is how the token-usage backfill's hour of wall clock would be spent here.
#
# IDEMPOTENCY IS THE TASK'S JOB
#
# The mechanism guarantees a task is not run *concurrently*, and that a
# `succeeded` task is never run again. It cannot guarantee a task that died
# halfway did not half-apply. Write `up` so that running it twice is harmless —
# an upsert, a `delete_all` of a shrinking set, a `where(... IS NULL)` guard —
# exactly as you would a data migration.
class PostDeployTask
  # Return this from `up` to be resumed on the next tick rather than marked done.
  CONTINUE = :continue

  attr_reader :run, :deadline, :logger

  def initialize(run:, deadline: nil, logger: Rails.logger)
    @run = run
    @deadline = deadline
    @logger = logger
  end

  # The work. Return CONTINUE to be resumed; anything else means done.
  def up
    raise NotImplementedError, "#{self.class.name} must define #up"
  end

  # Whatever this task needs to resume — a last id, a directory name, a page
  # token. A plain Hash with string keys, round-tripped through jsonb.
  def cursor = run.cursor

  # Counters worth showing a human. Rendered verbatim on the health panel and in
  # the Supervisor row, so name the keys for a reader rather than for the code.
  def stats = run.stats

  # Has the slice used up its budget? A task doing bulk work should check this
  # between chunks and return CONTINUE when it is true.
  def out_of_time?(now: Time.current) = deadline.present? && now >= deadline

  # Persist progress. One write, called after a chunk has committed, so a slice
  # that dies loses at most the chunk it was in the middle of.
  def checkpoint!(cursor: nil, **counters)
    run.cursor = cursor.as_json if cursor
    run.stats = run.stats.merge(counters.stringify_keys) if counters.any?
    run.save!
    run
  end

  # Walk a relation in key order, resuming from the cursor and stopping when the
  # budget runs out.
  #
  # This is the shape almost every slow post-deploy task wants, and getting it
  # wrong by hand is how you get a task that restarts from the beginning on every
  # tick and never finishes. Yields each batch; returns CONTINUE if it stopped on
  # the clock, nil once the relation is exhausted — so `def up = sweep(...) { }`
  # is a complete, resumable task.
  #
  # The relation must be stable under the key: rows the block *removes* are fine
  # (the cursor only moves forward), rows inserted behind the cursor are not
  # revisited. Order by the primary key unless you have a reason not to.
  #
  # THE BUDGET IS CHECKED BETWEEN BATCHES, NOT INSIDE ONE. A single batch query
  # runs to completion however long it takes, so the budget only bounds the slice
  # if each query is cheap. That is a constraint on the relation you pass: a
  # predicate the database can serve from an index stays cheap even at the tail,
  # where the query has to prove there is nothing left. An unindexed predicate on
  # a large table does not, and the last query of the sweep is a full scan — fine
  # for a table of thousands, not for one of millions.
  def sweep(relation, batch_size: 500, key: :id)
    cursor_key = "sweep_last_#{key}"
    last = cursor[cursor_key]

    loop do
      scope = relation.reorder(key => :asc).limit(batch_size)
      scope = scope.where(relation.arel_table[key].gt(last)) unless last.nil?
      batch = scope.to_a

      return nil if batch.empty?

      yield batch

      last = batch.last.public_send(key)
      checkpoint!(cursor: cursor.merge(cursor_key => last))

      return CONTINUE if out_of_time?
    end
  end
end
