# Board visibility: a second, presentation-only axis alongside `status`.
#
# It exists so the dashboard can be tidied — hide a session, or snooze it out of
# sight until a chosen time — and it touches nothing else. Nothing in the
# scheduler, the spot queue, the quota gate or the state machine reads either
# column, and setting them never starts, stops, sleeps or wakes a session.
#
# `snoozed_until` is only meaningful while `visibility = 'snoozed'`, and an
# expired snooze is treated as visible on read (Session#board_visible) rather
# than swept back by a job — no row has to be mutated for a snooze to end.
class AddVisibilityToSessions < ActiveRecord::Migration[8.0]
  def change
    add_column :sessions, :visibility, :string, default: "visible", null: false
    add_column :sessions, :snoozed_until, :datetime

    # Covers both halves of the derived predicate: the equality on `visibility`
    # and the `snoozed_until <= now()` comparison that decides whether a snooze
    # has run out.
    add_index :sessions, [ :visibility, :snoozed_until ]
  end
end
