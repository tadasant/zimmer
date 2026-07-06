# frozen_string_literal: true

# Job to recover sessions interrupted by deployment
#
# This job runs once on application startup (after a brief delay) to automatically
# continue sessions that were interrupted by a deployment restart.
#
# It handles three categories of sessions:
# 1. Sessions still marked as "running" but with no active GoodJob job
#    (deployment killed the worker mid-execution)
# 2. Sessions in "needs_input" (or "waiting") with paused_by: "recovery" metadata
#    (AgentSessionJob caught the InterruptError and marked for recovery,
#    or CleanupOrphanedSessionsJob already detected them as orphaned). The
#    "waiting" case covers sessions stranded by execute_pending_sleep when
#    pending_sleep lingered in metadata at recovery-pause time.
# 3. Sessions recently failed due to GoodJob::InterruptError
#    (safety net: if the InterruptError rescue in AgentSessionJob failed to
#    transition to needs_input, e.g. due to DB connection loss during shutdown)
#
# Sessions that legitimately need user input (paused_by: "user") are NOT affected.
#
# This is distinct from CleanupOrphanedSessionsJob which runs every 5 minutes
# and transitions orphaned sessions to needs_input. This job runs once on startup
# and automatically continues those deployment-orphaned sessions.
class DeploymentRecoveryJob < ApplicationJob
  include SessionContinuation
  queue_as :default

  # Limit how many sessions we recover at once to avoid overwhelming the system
  RECOVERY_LIMIT = 50

  def perform
    Rails.logger.info "[DeploymentRecoveryJob] Starting deployment recovery"

    recovered_count = 0
    failed_count = 0

    # Find sessions that need recovery
    sessions_to_recover = find_deployment_orphaned_sessions

    if sessions_to_recover.empty?
      Rails.logger.info "[DeploymentRecoveryJob] No deployment-orphaned sessions to recover"
      return
    end

    Rails.logger.info "[DeploymentRecoveryJob] Found #{sessions_to_recover.count} session(s) to recover"

    sessions_to_recover.each do |session|
      success = recover_session(session)
      if success
        recovered_count += 1
      else
        failed_count += 1
      end
    end

    Rails.logger.info "[DeploymentRecoveryJob] Completed: #{recovered_count} recovered, #{failed_count} failed"
  end

  private

  # Find sessions that were orphaned by deployment
  #
  # Sessions in a frozen category are a parked bucket and are excluded from every
  # query below, so deployment recovery never touches them (this also covers the
  # auto-continuation path in recover_session, which bypasses SessionRecoveryService).
  def find_deployment_orphaned_sessions
    sessions = []

    # Category 1: Sessions stuck in "running" with no active job
    # These are sessions where deployment killed the worker before it could
    # transition the session to needs_input
    running_orphans = Session.not_in_frozen_category.where(status: :running).select do |session|
      orphaned_running_session?(session)
    end
    sessions.concat(running_orphans)

    # Category 2: Sessions paused by recovery (not user action)
    # These were already detected by CleanupOrphanedSessionsJob and transitioned
    # to needs_input with paused_by: "recovery", or AgentSessionJob caught an
    # InterruptError and transitioned them directly.
    #
    # Normally these are in "needs_input", but a session that had pending_sleep in
    # metadata when recovery paused it gets bounced needs_input → waiting by the
    # pause callback's execute_pending_sleep — with no wake trigger to ever resume
    # it. We catch "waiting" too so those stranded sessions get auto-continued.
    # The paused_by: "recovery" marker is only ever written by the recovery system,
    # so a legitimately-dormant wake_me_up_later session (which reaches waiting via
    # pending_sleep WITHOUT paused_by) is never matched here.
    recovery_paused = Session
      .not_in_frozen_category
      .where(status: [ :needs_input, :waiting ])
      .where("metadata->>'paused_by' = 'recovery'")
      .to_a
    sessions.concat(recovery_paused)

    # Category 3: Sessions recently failed due to GoodJob::InterruptError
    # Safety net for when the InterruptError rescue block in AgentSessionJob
    # failed to transition to needs_input (e.g., DB connection lost during
    # shutdown). These sessions have exception_class set to the InterruptError.
    interrupt_failed = Session
      .not_in_frozen_category
      .where(status: :failed)
      .where("metadata->>'exception_class' = 'GoodJob::InterruptError'")
      .to_a
    sessions.concat(interrupt_failed)

    # Deduplicate and limit
    sessions.uniq.first(RECOVERY_LIMIT)
  end

  # Check if a running session is orphaned (no active job managing it)
  def orphaned_running_session?(session)
    # No job ID means definitely orphaned
    return true if session.running_job_id.blank?

    # Check if the job exists and is healthy
    job = GoodJob::Job.find_by(active_job_id: session.running_job_id)

    # No job record means orphaned
    return true unless job

    # Job finished (successfully or with error) means orphaned
    return true if job.finished_at.present?

    # Job has an error recorded means orphaned
    return true if job.error.present?

    # Job is not being processed and was created more than 2 minutes ago
    # (should have started by now if the system were healthy)
    if job.locked_by_id.blank? && job.scheduled_at.blank? && job.created_at < 2.minutes.ago
      return true
    end

    false
  end

  # Attempt to recover a single session
  def recover_session(session)
    # First, run the standard recovery service to handle process state
    if session.running?
      service = SessionRecoveryService.new(session)
      service.recover
      session.reload
    end

    # For sessions that failed due to InterruptError (deploy kill), transition
    # to needs_input with recovery marker so they can be auto-continued below.
    if session.failed? && session.metadata&.dig("exception_class") == "GoodJob::InterruptError"
      Rails.logger.info "[DeploymentRecoveryJob] Recovering InterruptError-failed session #{session.id}"
      session.logs.create!(
        content: "Recovering session that failed due to deploy interruption (GoodJob::InterruptError)",
        level: "info"
      )
      # Clear the failure metadata and mark for recovery continuation
      session.update!(
        running_job_id: nil,
        metadata: (session.metadata || {}).except(
          "failure_reason", "exception_class", "exception_message"
        ).merge("paused_by" => "recovery")
      )
      # Transition from failed → running (via resume) will happen in continue_recovered_session
    end

    # Now, if the session is eligible for auto-continuation, continue it.
    # Eligible means: paused_by recovery AND either needs_input (normal path),
    # waiting (stranded by execute_pending_sleep — resume transitions
    # waiting → running), or still failed with recovery marker (InterruptError
    # path where resume will transition failed → running inside
    # continue_recovered_session).
    if session.metadata&.dig("paused_by") == "recovery" &&
       (session.needs_input? || session.waiting? || session.failed?)
      continue_recovered_session(session)
    else
      true
    end
  rescue => e
    Rails.logger.error "[DeploymentRecoveryJob] Error recovering session #{session.id}: #{e.message}"
    session.logs.create!(
      content: "Deployment recovery failed: #{e.message}",
      level: "error"
    )
    false
  end

  def continuation_source
    "deployment recovery"
  end
end
