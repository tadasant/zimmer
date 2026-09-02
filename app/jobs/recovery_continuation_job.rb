# frozen_string_literal: true

# Continue ONE session that a recovery path just parked, without waiting for a cron
# to come round to it.
#
# ## Why this exists
#
# A recovery pause (`paused_by: "recovery"`) is a promise: the session says nothing
# to watchers and sends no push, because a sweep is going to continue it. With only
# CleanupOrphanedSessionsJob's five-minute cron to keep it, the interval between
# "recovery gave up" and "something happened" is whatever is left of that cron's
# period. Production session 12265 waited nine and a half minutes.
#
# The two mechanisms can also cancel out. The nudge AgentSessionJob enqueues after a
# worker interruption is dropped when a recovery job is already queued ("Skipping job
# - session already has a running job"); when that recovery job then fails to adopt
# its dead pid it re-enqueues nothing at all, and the session is left with no pending
# work of any kind.
#
# So the party that parks the session also asks for the continuation, on a short
# delay. This job is deliberately thin: it delegates to the very same
# SessionContinuation the sweeps use, so there is one implementation of "continue a
# recovery-paused session" and one attempt budget.
#
# Racing a cron tick is bounded rather than impossible. The automated-prompt path is
# safe outright — Session#claim_system_recovery_turn! re-reads the row `FOR UPDATE`
# and refuses a session something else is already driving. The queued-user-message
# path SessionContinuation tries first takes no such lock, so two continuations
# landing in the same instant can both reach EnqueuedMessageProcessorService; that
# race is shared with the two existing sweeps and is not made safe here, only more
# reachable, which is why the delay is 30 seconds rather than zero.
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
