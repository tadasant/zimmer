# frozen_string_literal: true

# Drop the manual "blocked by" relationship between sessions.
#
# The feature let a session be marked as blocked by another session, which hid it
# from the default dashboard until the blocker was trashed. It went unused, so the
# column, its index and its self-referential foreign key go with it.
#
# Reversible: `down` restores the column exactly as
# 20260609120000_add_blocked_by_session_to_sessions created it. The pointers
# themselves are not restored — dropping a column discards its values.
class DropBlockedBySessionFromSessions < ActiveRecord::Migration[8.0]
  def up
    remove_foreign_key :sessions, :sessions, column: :blocked_by_session_id
    remove_reference :sessions, :blocked_by_session, index: true
  end

  def down
    add_reference :sessions, :blocked_by_session, null: true, index: true
    add_foreign_key :sessions, :sessions, column: :blocked_by_session_id, on_delete: :nullify
  end
end
