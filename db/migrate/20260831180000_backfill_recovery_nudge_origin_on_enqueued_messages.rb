# frozen_string_literal: true

# Stamp the recovery nudges already sitting in session queues.
#
# `enqueued_messages.origin` gained `automated_recovery_nudge` so that the
# strand alert can tell a message Zimmer wrote to a session from one it accepted
# on somebody's behalf. Only new rows get the stamp from
# SpotSessionHold#queue_behind_scheduled_turn, and the rows that produced the
# 2026-08-31 page are already in the table as `caller`. Without this the same
# alert keeps firing on the queues that exist today.
#
# Matching on content is available only here, and only because the SYSTEM_RECOVERY
# template has been stable text since it was written — from now on the column
# carries the answer and nothing has to read the body to find it. This is the
# same shape as the backfill in AddOriginToEnqueuedMessages.
class BackfillRecoveryNudgeOriginOnEnqueuedMessages < ActiveRecord::Migration[8.0]
  # The opening two lines of AutomatedPrompts::SYSTEM_RECOVERY. Anchored at the
  # start of the body and matched across a long run of the template rather than
  # on a short phrase anywhere in it: a caller could in principle paste text that
  # satisfies a loose match, and mis-stamping a caller's message would exempt it
  # from the strand alert permanently.
  NUDGE_PREFIX = <<~TEXT.strip
    [AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]

    This session may have been interrupted by a system event (deployment restart, process termination, or transient failure). This is an automated nudge from Zimmer to check on your status.
  TEXT

  def up
    # Bounded to the two statuses any reader consults, so a `sent`/`processing`
    # row in flight is left alone. `caller` only: a row already carrying an
    # automated origin was stamped by a writer that knew better than a LIKE does.
    execute(<<~SQL.squish)
      UPDATE enqueued_messages
      SET origin = 'automated_recovery_nudge', updated_at = NOW()
      WHERE status IN ('pending', 'undelivered')
        AND origin = 'caller'
        AND content LIKE #{connection.quote("#{NUDGE_PREFIX}%")}
    SQL
  end

  def down
    execute(<<~SQL.squish)
      UPDATE enqueued_messages
      SET origin = 'caller', updated_at = NOW()
      WHERE origin = 'automated_recovery_nudge'
    SQL
  end
end
