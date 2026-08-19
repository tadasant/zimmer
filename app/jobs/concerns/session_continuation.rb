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
  # that was paused before it ever started has no runtime session_id and no clone
  # on disk, and nothing about waiting longer will produce either. Both sweeps
  # match `paused_by = 'recovery'`, so without a bound the cleanup cron re-reads
  # the same session every five minutes forever — one session that never ran
  # produced 500+ identical "auto-continue skipped" log lines over 20 hours.
  #
  # Giving up drops the `paused_by` marker, which is what both sweeps select on,
  # so the session stops being swept. It stays in needs_input for a human, which
  # is the honest state for a session Zimmer cannot restart on its own.
  MAX_CONTINUE_ATTEMPTS = 5

  # Counts failed auto-continue attempts. Cleared with the rest of
  # Session::STALE_RETRY_METADATA_KEYS whenever the session is successfully resumed.
  CONTINUE_ATTEMPTS_KEY = "recovery_continue_attempts"

  # Records that this session was abandoned by auto-continue, and why. Read by
  # nothing — it exists so the session page and a later reader can tell a session
  # Zimmer gave up on apart from one it never looked at.
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

    ActiveRecord::Base.transaction do
      # Clear stale retry metadata before resuming.
      # See Session::STALE_RETRY_METADATA_KEYS for the full list of keys cleared.
      session.update!(
        running_job_id: nil,
        metadata: (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)
      )

      session.resume_for_system_recovery!

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

    Rails.logger.info "[#{self.class.name}] Session #{session.id} recovered and continued"
    true
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

    if attempts >= MAX_CONTINUE_ATTEMPTS
      # Drop paused_by so both sweeps stop selecting this session, and say so once
      # rather than repeating the same skip line indefinitely.
      session.update!(
        metadata: (session.metadata || {})
          .except("paused_by", CONTINUE_ATTEMPTS_KEY)
          .merge(CONTINUE_ABANDONED_KEY => error_message)
      )
      session.logs.create!(
        content: "Recovery auto-continue gave up after #{attempts} attempts: #{error_message}. " \
                 "This session will not be retried again — restart it to try once more.",
        level: "error"
      )
      return false
    end

    session.update!(metadata: (session.metadata || {}).merge(CONTINUE_ATTEMPTS_KEY => attempts))
    session.logs.create!(
      content: "Recovery auto-continue skipped (attempt #{attempts} of #{MAX_CONTINUE_ATTEMPTS}): #{error_message}",
      level: "warning"
    )
    false
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
