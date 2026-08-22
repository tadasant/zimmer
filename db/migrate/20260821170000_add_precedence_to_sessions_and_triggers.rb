# frozen_string_literal: true

# Rank-orders the spot queue.
#
# `scheduling_class` answers "does this session wait for quota headroom". It says
# nothing about which of the waiting ones goes first, and with a permanently long
# spot queue that is the question that actually decides what gets done: whenever
# quota frees up, Zimmer picks an arbitrary spot session rather than the one that
# matters most.
#
# `precedence` is that ordering. Higher is handled sooner, on an ABSOLUTE scale —
# 100000 comes before 50. It is not a 1..N rank and nothing renumbers it, so the
# values stay sparse on purpose and a session can always be slotted between two
# others.
#
# It lives on every session, not only spot ones. A priority session demoted to
# spot has to land somewhere sensible, and a spot session promoted to priority has
# to keep its place for when it is demoted back — a column that only existed for
# half the rows would lose that on every round trip.
#
# The trigger column is the same value predefined: sessions a trigger spawns
# inherit it, so a noisy feed can be ranked once rather than one session at a
# time. NULL there means "say nothing", exactly as `scheduling_class` does.
class AddPrecedenceToSessionsAndTriggers < ActiveRecord::Migration[8.0]
  def change
    # NOT NULL with a default on sessions: every session has a place in the order,
    # and "no precedence" is not a state the ranked view could render.
    add_column :sessions, :precedence, :integer, null: false, default: 0

    # Nullable on triggers: NULL is "derive it", the same shape scheduling_class
    # already uses there.
    add_column :triggers, :precedence, :integer

    # The ranked view's ordering, and the fleet-wake skill's read. Partial on
    # unarchived rows because that is the only population either one orders.
    add_index :sessions, [ :precedence, :created_at ],
      where: "status <> 3", name: "index_sessions_on_precedence_unarchived"
  end
end
