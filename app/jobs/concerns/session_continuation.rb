# frozen_string_literal: true

require "automated_prompts"

# Shared logic for auto-continuing sessions that were paused by recovery.
#
# Used by both CleanupOrphanedSessionsJob and DeploymentRecoveryJob to
# resume sessions that were transitioned to needs_input by the recovery
# system (not by the user).
#
# Including classes should define a `continuation_source` method that returns
# a string identifying the caller (e.g., "deployment recovery", "orphan cleanup").
module SessionContinuation
  extend ActiveSupport::Concern

  # How many times a sweep will try to auto-continue one recovery-paused session
  # before giving up on it.
  #
  # The validation below can fail for a reason that will never change: a session
  # paused before it ever started has no runtime session_id and no clone on disk,
  # and nothing about waiting longer will produce either. Both sweeps match
  # `paused_by = 'recovery'`, so without a bound the cleanup cron re-reads the
  # same session every five minutes forever — one session that never ran produced
  # 500+ identical "auto-continue skipped" log lines over 20 hours.
  #
  # The other failure the validation reports — a working directory that is not
  # there — can be transient: a volume not yet mounted after a boot, a clone being
  # restored. The budget is sized for that rather than for the permanent case, at
  # roughly an hour against the 5-minute cron, so a blip clears long before the
  # sweep gives up.
  #
  # Giving up drops the `paused_by` marker, which is what both sweeps select on,
  # so the session stops being swept. It comes to rest wherever it already was —
  # `needs_input` or `waiting` on the ordinary path, still `failed` when the
  # caller was the InterruptError-failed branch — for a human to restart, which is
  # the honest state for a session Zimmer cannot restart on its own.
  #
  # With one exception, and it is the permanent case above: a session that never
  # ran has nothing to hand a human, so `Sessions::ReturnToQueue` sends it back to
  # `waiting` rather than leaving it in the action queue (#602).
  MAX_CONTINUE_ATTEMPTS = 12

  # Counts failed auto-continue attempts. Listed in
  # Session::STALE_RETRY_METADATA_KEYS, so it is cleared by the resume/restart
  # paths that clear that set — including the successful continue below.
  CONTINUE_ATTEMPTS_KEY = "recovery_continue_attempts"

  # Records that this session was abandoned by auto-continue, and why, so a later
  # reader can tell a session Zimmer gave up on from one it never looked at.
  CONTINUE_ABANDONED_KEY = "recovery_continue_abandoned"

  private

  # Continue a session that was paused by recovery.
  #
  # Validates the session has the required metadata (session_id, working_directory),
  # clears stale retry metadata, transitions to running, and enqueues a job to resume.
  #
  # If the user queued a follow-up message while the session was running/orphaned,
  # that message is delivered instead of the automated recovery prompt — otherwise
  # repeated recovery cycles (deploys, orphan cleanup) would leapfrog the user's
  # pending input with SYSTEM_RECOVERY on every pass, making the session appear to
  # ignore the user's messages.
  #
  # @param session [Session] the session to continue
  # @return [Boolean] true if session was continued, false if validation failed
  def continue_recovered_session(session)
    errors = validate_session_for_continue(session)
    if errors.any?
      return abandon_or_retry_continue(session, errors.join(", "))
    end

    # Prefer delivering a queued user message over the automated recovery
    # prompt. On success we're done; if delivery fails (e.g. a race, or the
    # session is in a state the processor won't resume), fall through to the
    # automated recovery prompt below — the message stays queued and drains at
    # the next clean turn boundary.
    if session.enqueued_messages.pending.exists? && continue_with_queued_user_message(session)
      return true
    end

    # The transaction is here for the LOCK, not for a rollback. `find_each` handed
    # us a session object read at the top of the sweep, and the row may have been
    # archived since; claim_system_recovery_turn! re-reads it `FOR UPDATE`, and
    # that lock is held until this block commits — so the enqueue below cannot
    # straddle an archive. A refused claim writes nothing, so there is nothing to
    # undo and `next` is the whole handling.
    outcome = nil
    ActiveRecord::Base.transaction do
      outcome = session.claim_system_recovery_turn! do
        # Clear stale retry metadata before resuming.
        # See Session::STALE_RETRY_METADATA_KEYS for the full list of keys cleared.
        session.update!(
          running_job_id: nil,
          metadata: (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)
        )
      end

      next unless outcome == :claimed

      # Enqueue a job with the automated recovery prompt, naming the sweep that sent it
      # so the agent (and whoever reads the transcript) can tell this apart from the
      # other paths that share the constant.
      AgentSessionJob.enqueue_with_prompt(
        session.id,
        AutomatedPrompts.system_recovery(reason: "Zimmer's #{continuation_source} resumed this session")
      )

      session.logs.create!(
        content: "Session automatically continued after #{continuation_source}",
        level: "info"
      )
    end

    return refuse_recovery_turn(session, outcome) unless outcome == :claimed

    Rails.logger.info "[#{self.class.name}] Session #{session.id} recovered and continued"
    true
  end

  # Say why a recovery turn was refused, on the session's own timeline, and tell
  # the sweep it did not continue this session.
  #
  # Deliberately NOT routed through abandon_or_retry_continue: that counts attempts
  # against a budget and eventually drops `paused_by` so the sweeps stop selecting
  # the session. Neither refusal here wants that. An archived session is already
  # invisible to both sweeps (they select on `needs_input` / `waiting` / `failed`),
  # so there is no loop to bound — and burning the budget, or dropping `paused_by`,
  # would sabotage the recovery that is owed to the session if it is later
  # unarchived. A `running` session is being driven by somebody else right now, and
  # will pause on its own.
  #
  # @param session [Session] the session whose claim was refused
  # @param outcome [Symbol] :archived or :not_resumable, from
  #   Session#claim_system_recovery_turn!
  # @return [Boolean] always false — the session was not continued
  def refuse_recovery_turn(session, outcome)
    message =
      if outcome == :archived
        "Not continuing this session after #{continuation_source}: it is in the trash. " \
        "An archived session takes no turn, so no agent was started and no prompt was delivered."
      else
        "Not continuing this session after #{continuation_source}: it is #{session.status} and " \
        "cannot be resumed. Something else is already driving it, so no second agent was started."
      end

    Rails.logger.info(
      "[#{self.class.name}] Session #{session.id} not continued after #{continuation_source}: #{outcome}"
    )
    # A session log rather than only a Rails log: "why did nothing happen to this
    # session" is asked from the session page, and a log that silently failed to
    # write would leave exactly the blank both sweeps' callers rescue around.
    session.logs.create!(content: message, level: "info")
    false
  end

  # Deliver the user's next pending enqueued message instead of the automated
  # recovery prompt, via EnqueuedMessageProcessorService — which atomically
  # claims the message, resumes the session (clearing paused_by), resets the
  # SIGTERM subset, and enqueues the job carrying the user's content.
  #
  # Metadata-clearing is deliberately split around the delivery to keep recovery
  # detection intact if delivery fails:
  #
  # - BEFORE delivery, clear running_job_id and the stale retry metadata EXCEPT
  #   paused_by. running_job_id must be cleared so the freshly-enqueued follow-up
  #   job isn't skipped by AgentSessionJob's concurrency guard; the other stale
  #   keys are not used for recovery detection, so clearing them early is safe.
  # - paused_by is PRESERVED until delivery succeeds. It is the recovery
  #   detection marker, and process_next_message returns false for states it
  #   won't resume (e.g. failed). When it does, the caller falls through to the
  #   automated recovery prompt, whose single transaction clears paused_by and
  #   resumes atomically — so if that transaction raises, the session is left
  #   with paused_by intact and stays detectable by the next recovery pass.
  #   Clearing paused_by here (outside any transaction) would strand the session
  #   if the fall-through transaction then failed.
  # - AFTER a successful delivery, drop paused_by. The resume! path already
  #   cleared it via clear_paused_by_metadata; this only matters for the
  #   running-handoff path (process_next_message does not resume an
  #   already-running session), where it would otherwise linger.
  #
  # @param session [Session] the recovery-paused session with a pending message
  # @return [Boolean] true if a queued message was delivered, false otherwise
  #   (caller then falls back to the automated recovery prompt)
  def continue_with_queued_user_message(session)
    stale_keys_except_paused_by = Session::STALE_RETRY_METADATA_KEYS - %w[paused_by]
    session.update!(
      running_job_id: nil,
      metadata: (session.metadata || {}).except(*stale_keys_except_paused_by)
    )

    return false unless EnqueuedMessageProcessorService.new(session).process_next_message

    session.reload
    if session.metadata&.dig("paused_by").present?
      session.update!(metadata: session.metadata.except("paused_by"))
    end

    session.logs.create!(
      content: "Session continued after #{continuation_source} by delivering queued user message",
      level: "info"
    )
    Rails.logger.info "[#{self.class.name}] Session #{session.id} continued via queued user message"
    true
  end

  # Record a failed auto-continue attempt, and stop sweeping the session once the
  # attempt budget is spent.
  #
  # @param session [Session] the session that could not be continued
  # @param error_message [String] why validation failed
  # @return [Boolean] always false — the session was not continued
  def abandon_or_retry_continue(session, error_message)
    attempts = session.metadata&.dig(CONTINUE_ATTEMPTS_KEY).to_i + 1
    Rails.logger.warn "[#{self.class.name}] Cannot continue session #{session.id}: #{error_message}"

    # merge_metadata!, not update!. A read-modify-write through update! would run
    # Session's validations, and those include the agent-root/catalog check that
    # fails globally when the artifact catalog cannot resolve. The RecordInvalid
    # would be swallowed by the caller's per-session rescue and the counter would
    # never advance — restoring the unbounded loop this bound exists to close, for
    # exactly the sessions least likely to be recoverable.
    if attempts >= MAX_CONTINUE_ATTEMPTS
      # Drop paused_by so both sweeps stop selecting this session, and say so once
      # rather than repeating the same skip line indefinitely.
      session.merge_metadata!(
        { CONTINUE_ABANDONED_KEY => error_message },
        [ "paused_by", CONTINUE_ATTEMPTS_KEY ]
      )
      session.logs.create!(
        content: "Recovery auto-continue gave up after #{attempts} attempts: #{error_message}. " \
                 "This session will not be retried again — restart it to try once more.",
        level: "error"
      )
      # A session that never ran has nothing to hand back to a human, and the
      # `needs_input` this abandonment would leave it in is both a slot in the
      # action queue and a dead end — every path that starts a session reads
      # `waiting`. Return it to the queue instead, where StalledSessionStart or
      # the spot gate's own sweep will re-dispatch it. Declines for a session
      # that HAS a conversation behind it, which is the case this give-up was
      # always about: a clone that is gone and a runtime session to resume into
      # it (#602).
      Sessions::ReturnToQueue.call(
        session,
        reason: "recovery could not continue it (#{error_message})",
        working_directory: session.metadata&.dig("working_directory")
      )

      # The missing-PR warning the recovery pause deferred (#558) comes due here,
      # and it is due whatever state the session is abandoned in — unlike the
      # announcement below, which is only honest about a session that really is
      # resting in `needs_input`. A recovery pause carrying `pending_sleep` is
      # bounced straight on to `waiting` by `execute_pending_sleep`, with nothing
      # armed to resume it; that session is the most stranded of the lot, and it
      # is exactly the one the resting-state guard would skip. Never raises.
      session.warn_if_pr_goal_captured_no_url
      announce_abandoned_pause(session)
      return false
    end

    session.merge_metadata!(CONTINUE_ATTEMPTS_KEY => attempts)
    session.logs.create!(
      content: "Recovery auto-continue skipped (attempt #{attempts} of #{MAX_CONTINUE_ATTEMPTS}): #{error_message}",
      level: "warning"
    )
    false
  end

  # Say out loud what the recovery pause did not.
  #
  # A recovery pause fires no `session_needs_input` wake and sends no push
  # (SessionStateMachine's `pause` after block), on the promise that one of these
  # sweeps will continue the session. Giving up is that promise expiring: the
  # session is now resting in the human action queue with nobody coming for it,
  # which is exactly the transition the pause would have announced. Making the
  # announcement here rather than at pause time is the whole reason the carve-out
  # is safe — otherwise suppressing it would fail silently in the direction of
  # less visibility.
  #
  # Only for a session actually resting in `needs_input`. The other two states this
  # abandonment can reach are already covered or are not a rest at all: a `failed`
  # session fired `session_failed` and an unconditional failure push when it failed,
  # and a `waiting` session is dormant — telling a watcher it "needs input" would be
  # a claim about a state it is not in, and the settled event would drop it anyway.
  def announce_abandoned_pause(session)
    return unless session.reload.resting_in_needs_input?

    session.announce_deferred_needs_input!
  rescue => e
    # Best-effort, exactly as on the pause path: the session is already in the
    # homepage action queue and carries the give-up log line, and a failed
    # notification must not stop the sweep reaching the next session.
    Rails.logger.error(
      "[#{self.class.name}] Failed to announce abandoned recovery pause for session #{session.id}: #{e.message}"
    )
  end

  # Validate session has required fields for continue
  def validate_session_for_continue(session)
    errors = []
    errors << "no session_id found" unless session.session_id.present?

    working_directory = session.metadata&.dig("working_directory")
    unless working_directory.present? && Dir.exist?(working_directory)
      errors << "working directory not found or invalid"
    end

    errors
  end

  # Override in including class to identify the source of continuation
  def continuation_source
    "recovery"
  end
end
