# frozen_string_literal: true

# A triager's record that a stranded backlog row is waiting on a HUMAN decision,
# so the row stops paging while it waits — and only while it waits (#1225).
#
#   held_at              when the hold was recorded.
#   held_until           when it lapses on its own. The row falls back into the
#                        stranded population, and so into the page, at this
#                        instant. There is no hold without an end.
#   held_by              who recorded it: the recording session's agent root, or
#                        "human" from the Issues page.
#   held_by_session_id   that session, for provenance.
#   hold_reason          the decision owed, in words. Required.
#   held_liveness_state  the liveness evidence the hold was recorded against. A
#                        sweep that reads anything else voids the hold.
#
# Not a status: a held row is still `started` or `removed`, exactly as before.
class AddHoldToWorkBacklogItems < ActiveRecord::Migration[8.0]
  def change
    add_column :work_backlog_items, :held_at, :datetime
    add_column :work_backlog_items, :held_until, :datetime
    add_column :work_backlog_items, :held_by, :string
    add_column :work_backlog_items, :hold_reason, :text
    add_column :work_backlog_items, :held_liveness_state, :string
    add_reference :work_backlog_items, :held_by_session, foreign_key: { to_table: :sessions, on_delete: :nullify }
  end
end
