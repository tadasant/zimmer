# frozen_string_literal: true

# Continue ONE session that a recovery path just parked, without waiting for a cron
# to come round to it.
#
# ## Why this exists (zimmer#807)
#
# A recovery pause (`paused_by: "recovery"`) is a promise: the session says nothing
# to watchers and sends no push, because a sweep is going to continue it. Until now
# the only thing keeping that promise was CleanupOrphanedSessionsJob's five-minute
# cron, so the interval between "recovery gave up" and "something happened" was
# whatever was left of that cron's period. Production session 12265 waited nine and
# a half minutes.
#
# Worse, the two mechanisms could cancel out. The nudge AgentSessionJob enqueues
# after a worker interruption is dropped when a recovery job is already queued
# ("Skipping job - session already has a running job"); when that recovery job then
# failed to adopt its dead pid, it re-enqueued nothing at all, and the session was
# left with no pending work of any kind.
#
# So the party that parks the session also asks for the continuation, on a short
# delay. This job is deliberately thin: it delegates to the very same
# SessionContinuation the sweeps use, so there is one implementation of "continue a
# recovery-paused session" and one attempt budget, and running twice is harmless —
# Session#claim_system_recovery_turn! takes a row lock and refuses a session
# something else is already driving.
class RecoveryContinuationJob < ApplicationJob
  include SessionContinuation

  queue_as :default

  # Long enough for the parking writes to commit and for any in-flight job to
  # release the session, short enough that nobody watching the session page reads
  # the pause as a stall. The cron sweep remains the backstop behind it.
  DELAY = 30.seconds

  # Ask for a continuation of a session that has just been parked by recovery.
  #
  # Best-effort by construction: a failure to enqueue must never be the thing that
  # breaks the recovery path, because the state the caller has already written is
  # exactly what CleanupOrphanedSessionsJob selects on.
  #
  # @param session [Session]
  # @return [ActiveJob::Base, nil]
  def self.schedule_for(session)
    return nil if session.blank?

    set(wait: DELAY).perform_later(session.id)
  rescue => e
    Rails.logger.error(
      "[RecoveryContinuationJob] Could not schedule a continuation for session #{session&.id}: #{e.message}"
    )
    nil
  end

  def perform(session_id)
    session = Session.find_by(id: session_id)
    return unless session

    # Every guard the sweeps apply, asked of this one row. The session may have been
    # continued, resumed by a human, archived or frozen in the delay window, and in
    # each of those cases the right move is to do nothing at all.
    return unless session.metadata&.dig("paused_by") == "recovery"
    return unless session.needs_input? || session.waiting?
    return if session.category&.is_frozen?

    continue_recovered_session(session)
  rescue => e
    Rails.logger.error "[RecoveryContinuationJob] Error continuing session #{session_id}: #{e.message}"
    session&.logs&.create(content: "Auto-continue failed: #{e.message}", level: "error")
  end

  private

  # A noun phrase: it is interpolated into "Zimmer's %s resumed this session" as
  # well as into this session's own timeline.
  def continuation_source
    "recovery retry"
  end
end
