class CleanupOrphanedSessionsJob < ApplicationJob
  include DatabaseRetry
  include SessionContinuation
  queue_as :default

  def perform
    recover_running_orphans
    continue_recovery_paused_sessions
  end

  private

  # Find and recover sessions stuck in 'running' status with no active job.
  # Sessions in a frozen category are a parked bucket and are excluded from every
  # query in this job, so the orphan cleanup never touches them (this also covers
  # the continuation paths below, which bypass SessionRecoveryService).
  def recover_running_orphans
    orphaned_sessions = Session.not_in_frozen_category.where(status: :running).select do |session|
      orphaned_running_session?(session)
    end

    orphaned_sessions.each do |session|
      recover_orphaned_session(session)
    end

    if orphaned_sessions.any?
      Rails.logger.info "[CleanupOrphanedSessionsJob] Cleaned up #{orphaned_sessions.count} orphaned session(s)"
    end
  end

  # Auto-continue sessions left in needs_input by recovery, and recover sessions
  # that failed due to GoodJob::InterruptError (deploy kill).
  #
  # This catches sessions that were transitioned to needs_input by:
  # - SessionRecoveryService (via recover_with_stopped_process)
  # - AgentSessionJob resume_monitoring (dead process detected in-container)
  # - AgentSessionJob InterruptError handler (deploy interrupted the job)
  # - CleanupOrphanedSessionsJob itself (from recover_orphaned_session above)
  #
  # It also catches sessions that failed due to InterruptError as a safety net,
  # in case the InterruptError handler couldn't transition to needs_input
  # (e.g., DB connection lost during shutdown).
  #
  # Without this, sessions can get stuck at needs_input if DeploymentRecoveryJob
  # already ran before the orphan was detected (race condition during deploys).
  #
  # We also catch "waiting" sessions with paused_by: "recovery". A session that
  # had pending_sleep in metadata when recovery paused it gets bounced
  # needs_input → waiting by the pause callback's execute_pending_sleep, with no
  # wake trigger to ever resume it — a permanently stranded dead state. The
  # paused_by: "recovery" marker is only ever written by the recovery system, so
  # this never disturbs a legitimately-dormant wake_me_up_later session (which
  # reaches waiting via pending_sleep WITHOUT paused_by).
  def continue_recovery_paused_sessions
    recovery_paused = Session
      .not_in_frozen_category
      .where(status: [ :needs_input, :waiting ])
      .where("metadata->>'paused_by' = 'recovery'")

    continued_count = 0
    recovery_paused.find_each do |session|
      if continue_recovered_session(session)
        continued_count += 1
      end
    rescue => e
      Rails.logger.error "[CleanupOrphanedSessionsJob] Error auto-continuing session #{session.id}: #{e.message}"
      session.logs.create(
        content: "Auto-continue failed: #{e.message}",
        level: "error"
      )
    end

    # Also recover sessions that failed due to InterruptError (deploy kill).
    # These sessions were caught by the general rescue block instead of the
    # InterruptError-specific one, or the InterruptError handler failed to
    # update the DB (e.g., connection lost during shutdown).
    # Also picks up sessions left in failed+paused_by:recovery if a prior
    # recovery attempt cleared exception_class but then failed before resuming.
    interrupt_failed = Session
      .not_in_frozen_category
      .where(status: :failed)
      .where(
        "metadata->>'exception_class' = 'GoodJob::InterruptError' OR " \
        "(metadata->>'paused_by' = 'recovery' AND metadata->>'exception_class' IS NULL)"
      )

    interrupt_failed.find_each do |session|
      Rails.logger.info "[CleanupOrphanedSessionsJob] Recovering InterruptError-failed session #{session.id}"
      session.logs.create!(
        content: "Recovering session that failed due to deploy interruption (GoodJob::InterruptError)",
        level: "info"
      )
      # Clear failure metadata and mark for recovery continuation
      session.update!(
        running_job_id: nil,
        metadata: (session.metadata || {}).except(
          "failure_reason", "oauth_required_servers", "exception_class", "exception_message"
        ).merge("paused_by" => "recovery")
      )
      if continue_recovered_session(session)
        continued_count += 1
      end
    rescue => e
      Rails.logger.error "[CleanupOrphanedSessionsJob] Error recovering InterruptError-failed session #{session.id}: #{e.message}"
      session.logs.create(
        content: "InterruptError recovery failed: #{e.message}",
        level: "error"
      )
    end

    if continued_count > 0
      Rails.logger.info "[CleanupOrphanedSessionsJob] Auto-continued #{continued_count} recovery-paused session(s)"
    end
  end

  def orphaned_running_session?(session)
    # Skip very recently created sessions. There's a brief window between session
    # creation and AgentSessionJob picking it up where the session has no running_job_id.
    # Without this grace period, sessions created in the same cron minute as this job
    # get falsely detected as orphans.
    if session.created_at > 30.seconds.ago
      return false
    end

    # Skip sessions that have a pending follow-up prompt being delivered.
    # The follow-up flow sets pending_follow_up_prompt in metadata before enqueuing
    # the job. If the job hasn't started yet, the session may appear orphaned
    # (running with no active job) but is actually about to be picked up.
    if session.metadata&.dig("pending_follow_up_prompt").present?
      return false
    end

    # Skip sessions parked for a scheduled transient-clone-failure retry.
    # AgentSessionJob re-enqueues the whole job with a backoff delay and points
    # running_job_id at that future-scheduled job (see schedule_transient_clone_retry).
    # While the retry is pending there is intentionally no live process to monitor,
    # so treat the session as alive rather than reaping it — otherwise the
    # last_timeline_entry_at staleness check below could recover it and race a
    # duplicate job against the pending retry.
    if session.metadata&.dig("clone_retry_count").to_i.positive?
      retry_job = GoodJob::Job.find_by(active_job_id: session.running_job_id)
      if retry_job&.finished_at.blank? &&
          retry_job&.scheduled_at.present? && retry_job.scheduled_at > Time.current
        return false
      end
    end

    # Sessions with no job are DEFINITELY orphaned
    if session.running_job_id.blank?
      return true  # Orphaned! No job monitoring this running session
    end

    # For sessions with a job ID, check if the job exists and is healthy
    job = GoodJob::Job.find_by(active_job_id: session.running_job_id)
    return true unless job # Job doesn't exist anymore

    # Check if job is finished
    return true if job.finished_at.present?

    # Check if job has an error (failed execution in GoodJob terms)
    return true if job.error.present?

    # Check if job is not being processed (orphaned)
    # In GoodJob, locked_by_id indicates if a job is being processed
    # Only check this if the job was created more than 5 minutes ago
    # to avoid false positives for jobs that are being queued
    if job.created_at < 5.minutes.ago
      is_scheduled = job.scheduled_at.present? && job.scheduled_at > Time.current
      is_locked = job.locked_by_id.present?
      return true if !is_scheduled && !is_locked

      # Even if the job appears locked, check if the lock is stale
      # (i.e., the locking process no longer exists - can happen after deploys)
      if is_locked
        lock_holder_exists = GoodJob::Process.exists?(id: job.locked_by_id)
        return true unless lock_holder_exists
      end
    end

    # Also check for sessions with no recent activity - their agent process may have died
    # even though the job is still "running" (polling a dead transcript)
    if session.last_timeline_entry_at.present? && session.last_timeline_entry_at < 15.minutes.ago
      return true
    end

    # NOTE: We intentionally do NOT check Process.kill(0, pid) here.
    # In multi-container deployments (e.g., Kamal rolling deploys), the cleanup job
    # may run in a different container than the one that spawned the Claude CLI process.
    # Each container has its own PID namespace, so Process.kill(0, pid) will return
    # ESRCH (No such process) even though the process is alive in another container.
    # This caused false orphan detection and premature needs_input transitions.
    #
    # The monitoring job (AgentSessionJob) runs in the same container as the process
    # it spawned, so it can reliably detect process death. If the monitoring job is
    # healthy (locked by an alive GoodJob process), we trust it to handle process
    # lifecycle. If the job itself is dead/stuck, the checks above will catch it.

    false
  end

  def recover_orphaned_session(session)
    job = GoodJob::Job.find_by(active_job_id: session.running_job_id)

    # Determine the reason for orphan detection
    is_hung_process = session.last_timeline_entry_at.present? && session.last_timeline_entry_at < 15.minutes.ago

    error_message = if job&.error.present?
      "Job failed: #{job.error.truncate(100)}"
    elsif job&.finished_at.present?
      "Job finished without updating session status"
    elsif job&.locked_by_id.present? && !GoodJob::Process.exists?(id: job.locked_by_id)
      "Job held stale lock from dead process (likely due to deploy)"
    elsif is_hung_process
      "No activity for #{((Time.current - session.last_timeline_entry_at) / 60).round} minutes"
    else
      "Job was orphaned or lost"
    end

    with_db_retry do
      session.logs.create!(
        content: "Detected orphaned session: #{error_message}",
        level: "warning"
      )
    end

    # Use SessionRecoveryService to attempt recovery
    # If the session has no activity for 15+ minutes, the process is likely hung.
    # Pass force_terminate_hung_process: true to terminate it instead of re-monitoring.
    recovery_service = SessionRecoveryService.new(
      session,
      force_terminate_hung_process: is_hung_process
    )
    recovery_service.recover

    # Note: auto-continue of recovery-paused sessions is handled by
    # continue_recovery_paused_sessions which runs after all orphans are processed.
    # This avoids issues with session state changes during iteration.
  end

  def continuation_source
    "orphan cleanup"
  end
end
