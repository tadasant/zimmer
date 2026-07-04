# Fix sessions.status database default: change from 0 (running) to 1 (waiting).
#
# The AASM state machine defines `waiting` as the initial state, but the database
# column default was 0 (running). This mismatch caused a race condition where
# newly created sessions appeared as "running" to CleanupOrphanedSessionsJob,
# which would detect them as orphans and transition them to needs_input before
# the AgentSessionJob had a chance to start.
#
# Root cause: When Rails initializes a new Session record, the status attribute
# gets its default from the database schema (0 = running) rather than from
# AASM's `initial: true` declaration on `waiting` (1). This is because AASM
# checks `column_already_set?` and defers to the existing attribute value.
class ChangeSessionsStatusDefaultToWaiting < ActiveRecord::Migration[8.0]
  def change
    change_column_default :sessions, :status, from: 0, to: 1
  end
end
