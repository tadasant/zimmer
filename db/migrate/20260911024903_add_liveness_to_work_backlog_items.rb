# frozen_string_literal: true

# What the liveness re-check found on a backlog row that has left `queued`.
#
# A row leaves `queued` by two routes — a pull starts it, or a pull removes it
# mechanically — and nothing reads the row again afterwards. When the premise
# expires (the session ended with the work unfinished, the PR the removal cited
# went quiet) the item is neither queued nor being worked, and nothing says so.
#
#   liveness_checked_at  when WorkBacklog::LivenessSweep last examined the row.
#                        Also the sweep's cursor: it takes the least-recently-
#                        checked rows first, so nothing starves.
#   liveness_state       what it found — one of WorkBacklogItem::LIVENESS_STATES.
#                        Evidence for a human to triage, never a decision: the
#                        sweep changes no row's status.
#
# The index serves the sweep's ordering — least-recently-checked first, nulls
# first. It is on `liveness_checked_at` alone rather than on `(status, …)`,
# because the candidate query has no single-status predicate to lead with: it is
# an OR over two `id IN (…)` arms, one per route out of the queue.
class AddLivenessToWorkBacklogItems < ActiveRecord::Migration[8.0]
  def change
    add_column :work_backlog_items, :liveness_checked_at, :datetime
    add_column :work_backlog_items, :liveness_state, :string

    add_index :work_backlog_items, :liveness_checked_at,
              name: "index_work_backlog_items_on_liveness"
  end
end
