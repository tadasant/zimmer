# frozen_string_literal: true

# What the liveness re-check found on a `started` row, and how many times it has
# put one back on the queue.
#
# A row that reaches `started` used to be terminal in practice: nothing looked at
# it again, so an implementing session that archived without closing its issue
# left the item neither queued nor being worked, invisibly and forever. These
# three columns are what WorkBacklog::StaleStartSweep writes when it re-examines
# such a row.
#
#   liveness_checked_at  when the sweep last examined it. Also the sweep's own
#                        cursor: it takes the least-recently-checked rows first,
#                        so nothing starves behind a long-lived population.
#   liveness_state       what it concluded — one of
#                        WorkBacklogItem::LIVENESS_STATES.
#   requeue_count        how many times this item has been put back. Bounded, so
#                        an item whose session dies on every attempt is left for
#                        a human instead of cycling forever.
#
# The index is the sweep's candidate query: `started` rows ordered by when they
# were last checked, nulls (never checked) first.
class AddLivenessToWorkBacklogItems < ActiveRecord::Migration[8.0]
  def change
    add_column :work_backlog_items, :liveness_checked_at, :datetime
    add_column :work_backlog_items, :liveness_state, :string
    add_column :work_backlog_items, :requeue_count, :integer, default: 0, null: false

    add_index :work_backlog_items, [ :status, :liveness_checked_at ],
              name: "index_work_backlog_items_on_liveness"
  end
end
