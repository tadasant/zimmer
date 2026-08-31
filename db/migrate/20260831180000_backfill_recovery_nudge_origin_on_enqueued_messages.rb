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
  # The opening two lines of AutomatedPrompts::SYSTEM_RECOVERY, including the
  # blank line between them. Anchored at the start of the body and matched across
  # a long run of the template rather than on a short phrase anywhere in it: a
  # caller could in principle paste text that satisfies a loose match, and
  # mis-stamping a caller's message would exempt it from the strand alert
  # permanently.
  #
  # Written out literally rather than read from AutomatedPrompts::SYSTEM_RECOVERY.
  # The rows this has to match hold the text as it stood when they were queued, so
  # a later edit to that constant must not retroactively change what this migration
  # matches — and a migration that replays years from now must behave the way it
  # did today.
  NUDGE_PREFIX = <<~TEXT.strip
    [AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]

    This session may have been interrupted by a system event (deployment restart, process termination, or transient failure). This is an automated nudge from Zimmer to check on your status.
  TEXT

  # The two statuses any reader consults. A `sent`/`processing` row is in flight
  # and is left alone in both directions.
  BACKFILLED_STATUSES = %w[pending undelivered].freeze

  def up
    pattern = "#{NUDGE_PREFIX}%"
    # The bug this guard exists for, caught the hard way in review: the first
    # draft built the statement with `<<~SQL.squish`, which runs
    # `gsub(/[[:space:]]+/, " ")` over the WHOLE statement — including the quoted
    # literal — and collapsed the template's blank line to a single space. The
    # pattern then matched no row in the table and the migration was a silent
    # no-op. Nothing downstream would have reported it: `LIKE` matching nothing is
    # not an error, and CI never executes migrations (it loads `db/schema.rb`).
    #
    # So: no whitespace-normalising call may touch this statement, and this
    # assertion fails the migration loudly if one ever does again.
    raise "NUDGE_PREFIX lost its blank line — the LIKE pattern would match nothing" unless pattern.include?("\n\n")

    result = connection.exec_update(
      "UPDATE enqueued_messages " \
      "SET origin = 'automated_recovery_nudge', updated_at = NOW() " \
      "WHERE status IN (#{quoted_statuses}) AND origin = 'caller' AND content LIKE #{connection.quote(pattern)}"
    )

    # An observable answer to "has it run, and what did it cover", per this repo's
    # rule that an ops action must give one. A backfill that legitimately matches
    # zero rows and one that matches zero because its pattern is broken look
    # identical afterwards; the count is what tells them apart in the deploy log.
    say "Stamped #{result} queued recovery nudge(s) as automated_recovery_nudge"
  end

  def down
    # Bounded to the same statuses `up` touched, so rollback-then-replay is a
    # round trip rather than a widening one. Rows the new code stamped at another
    # status are left alone here for the same reason `up` never claimed them.
    result = connection.exec_update(
      "UPDATE enqueued_messages " \
      "SET origin = 'caller', updated_at = NOW() " \
      "WHERE status IN (#{quoted_statuses}) AND origin = 'automated_recovery_nudge'"
    )
    say "Reverted #{result} queued recovery nudge(s) to caller"
  end

  private

  def quoted_statuses
    BACKFILLED_STATUSES.map { |status| connection.quote(status) }.join(", ")
  end
end
