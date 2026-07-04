# Service for recovering orphaned sessions and reconnecting to running processes
#
# This service is responsible for:
# - Recovering sessions by resuming monitoring of existing processes
# - Transitioning orphaned sessions to needs_input when process has no PID
# - Performing final transcript polls for stopped processes
# - Preventing duplicate recovery jobs from being enqueued
# - Terminating hung processes and auto-restarting them (when force_terminate_hung_process: true)
#
# IMPORTANT: By default (skip_pid_check: true), this service does NOT check
# Process.kill(0, pid) to determine if a process is alive. In multi-container
# deployments (e.g., Kamal), this service may run in a different container than
# the one that spawned the Claude CLI process. Each container has its own PID
# namespace, so Process.kill(0, pid) will falsely report ESRCH. Instead, we
# always attempt to re-monitor via AgentSessionJob (resume_monitoring: true),
# which runs in the same container as the process and can reliably check its status.
#
# NOTE: The force_terminate_hung_process path still sends signals via
# ProcessTerminationService, which has the same cross-container PID limitation.
# This is acceptable because hung process termination is a best-effort operation:
# if the signal fails (ESRCH), the process will eventually be cleaned up by the
# container runtime. A future improvement could route termination through the
# correct container.
#
# Usage:
#   service = SessionRecoveryService.new(session)
#   service.recover
#
# To forcefully terminate a process that appears hung (no activity but still "running"):
#   service = SessionRecoveryService.new(session, force_terminate_hung_process: true)
#   service.recover
class SessionRecoveryService
  include DatabaseRetry

  attr_reader :session, :process_manager

  # @param skip_pid_check [Boolean] When true (default), skips the local Process.kill(0, pid)
  #   check and always attempts re-monitoring. This is the correct behavior for
  #   multi-container deployments where PID namespaces differ. Tests pass false
  #   to exercise the process_still_running? path via injected MockProcessManager.
  def initialize(session, process_manager: nil, log_buffer: nil, force_terminate_hung_process: false, skip_pid_check: true)
    @session = session
    @process_manager = process_manager || SystemProcessManager.new
    @log_buffer = log_buffer
    @force_terminate_hung_process = force_terminate_hung_process
    @skip_pid_check = skip_pid_check
    @logger = StructuredLogger.new({ session_id: session.id, service: "SessionRecoveryService" })
  end

  # Recover an orphaned session
  #
  # @return [Boolean] true if session will continue running (monitoring enqueued or pending),
  #                   false if session transitioned to needs_input (process stopped or terminated)
  #
  # Note: There is a potential race condition where another process could enqueue a monitoring
  # job between the pending check and the actual enqueue. This is acceptable because:
  # 1. CleanupOrphanedSessionsJob is a singleton cron job (not run concurrently)
  # 2. Duplicate monitoring jobs are wasteful but not harmful
  # 3. The mitigation significantly reduces the problem even if it doesn't completely eliminate it
  def recover
    # Sessions parked in a frozen category are intentionally left alone by every
    # bulk recovery flow. Guarding here covers all callers (refresh-all, the
    # cleanup cron, and deployment recovery) from a single chokepoint. Return true
    # so callers treat the session as "handled" and don't transition it.
    if session.category&.is_frozen?
      add_log("Skipping recovery - category is frozen", level: "debug")
      @logger.info("Skipped recovery - frozen category", session_id: session.id, category_id: session.category_id)
      return true
    end

    # Check if there's already a pending monitoring job for this session
    # This prevents duplicate job enqueuing when CleanupOrphanedSessionsJob runs repeatedly
    if pending_monitoring_job_exists?
      add_log("Skipping recovery - pending monitoring job already exists", level: "debug")
      @logger.info("Skipped recovery - pending monitoring job exists", session_id: session.id)
      return true # Return true to indicate session is being handled
    end

    process_pid = session.metadata&.dig("process_pid")

    # When force_terminate_hung_process is set, the cleanup job detected prolonged
    # inactivity (15+ minutes). The process may be hung — terminate and restart.
    if @force_terminate_hung_process && process_pid
      recover_with_hung_process(process_pid)
      return true # Session will auto-restart
    end

    # For non-hung orphans: the monitoring job died but the process might still
    # be alive in another container. We cannot reliably check via Process.kill(0, pid)
    # because this recovery service may run in a different PID namespace than the
    # one that spawned the process.
    #
    # When skip_pid_check is true (production default), always try to re-monitor.
    # The AgentSessionJob with resume_monitoring: true will run in the correct
    # container and check the PID locally — if the process is dead, it'll
    # transition to needs_input.
    #
    # When skip_pid_check is false (tests), use the injected process_manager
    # to check locally so tests can control the behavior.
    if process_pid && (@skip_pid_check || process_still_running?(process_pid))
      recover_with_running_process(process_pid)
      true
    else
      recover_with_stopped_process(process_pid)
      false
    end
  end

  # Check if a pending monitoring job already exists for this session
  # @return [Boolean] true if a pending job exists, false otherwise
  def pending_monitoring_job_exists?
    # Check both GoodJob database (production) and ActiveJob test adapter (tests)
    goodjob_pending = check_goodjob_for_pending_monitoring_jobs
    test_adapter_pending = check_test_adapter_for_pending_monitoring_jobs

    goodjob_pending || test_adapter_pending
  rescue => e
    @logger.error("Error checking for pending monitoring jobs", error: e.message)
    false # Err on the side of allowing recovery if we can't check
  end

  # Check if a process is still running
  # @param pid [Integer] The process ID to check
  # @return [Boolean] true if the process is running, false otherwise
  def process_still_running?(pid)
    return false unless pid

    @process_manager.running?(pid)
  end

  private

  # Check GoodJob database for pending monitoring jobs
  # Used in production/development where GoodJob stores jobs in the database
  #
  # Uses PostgreSQL JSONB operators for efficient querying without loading records into memory.
  # The serialized_params structure looks like:
  #   {"arguments": [session_id, nil, {"resume_monitoring": true, "_aj_symbol_keys": ["resume_monitoring"]}]}
  #
  # Important: We exclude jobs that have already started executing (performed_at IS NOT NULL)
  # but never finished. These are zombie/stuck jobs that should NOT block recovery.
  # A hard worker crash (SIGKILL, OOM kill, etc.) can leave a job with performed_at set
  # but finished_at nil, causing recovery to be permanently blocked.
  def check_goodjob_for_pending_monitoring_jobs
    GoodJob::Job.where(finished_at: nil, performed_at: nil, job_class: "AgentSessionJob")
      .where("serialized_params->'arguments'->0 = ?", session.id.to_json)
      .where("serialized_params->'arguments'->2->>'resume_monitoring' = 'true'")
      .exists?
  rescue => e
    @logger.error("Error checking GoodJob for pending monitoring jobs", error: e.message)
    false
  end

  # Check ActiveJob test adapter for pending monitoring jobs
  # Used in tests where jobs are stored in memory
  def check_test_adapter_for_pending_monitoring_jobs
    return false unless Rails.env.test?

    enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs || []
    enqueued_jobs.any? do |job|
      job["job_class"] == "AgentSessionJob" && monitoring_job_for_session?(job["arguments"])
    end
  rescue => e
    @logger.error("Error checking test adapter for pending monitoring jobs", error: e.message)
    false
  end

  # Check if job arguments represent a monitoring job for this session
  def monitoring_job_for_session?(args)
    return false unless args.is_a?(Array)

    session_id_arg = args[0]
    options = args[2]

    session_id_arg == session.id &&
      options.is_a?(Hash) &&
      (options["resume_monitoring"] == true || options[:resume_monitoring] == true)
  end

  # Recover session when the Claude CLI process appears hung
  # (no activity for extended period but process still exists)
  # Terminates the process and auto-restarts the session
  def recover_with_hung_process(process_pid)
    add_log("Claude CLI process #{process_pid} appears hung (no activity). Terminating...", level: "warning")
    @logger.warn("Terminating hung process", process_pid: process_pid, session_id: session.id)

    # Set a metadata flag BEFORE killing the process so the monitoring loop's
    # handle_exit method knows this was a recovery-initiated termination and
    # returns :aborted instead of :failed. Without this, there's a race condition:
    # the monitoring loop detects the SIGKILL exit and transitions to failed
    # before we can transition to needs_input.
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge("recovery_termination_initiated" => true)
      )
    end

    # Terminate the hung process
    termination_service = ProcessTerminationService.new(
      process_pid: process_pid,
      process_manager: @process_manager,
      log_buffer: @log_buffer,
      session: session
    )
    result = termination_service.terminate

    if result.success?
      add_log("Hung process #{process_pid} terminated: #{result.message}", level: "info")
    else
      add_log("Failed to terminate hung process #{process_pid}: #{result.message}", level: "error")
    end

    # Poll transcript one last time to get any messages
    add_log("Performing final transcript poll after hung process termination...", level: "verbose")
    poller = TranscriptPollerService.new(session)
    poller.poll_and_broadcast

    transition_to_needs_input

    # Check for and process any enqueued messages first
    processor = EnqueuedMessageProcessorService.new(session, log_buffer: @log_buffer)
    if processor.process_next_message
      add_log("Enqueued message being processed after hung process recovery", level: "info")
      @logger.info("Processed enqueued message after hung process recovery", process_pid: process_pid)
    else
      # No enqueued messages — auto-restart the session so it picks up where it left off.
      # This mirrors the deployment recovery behavior in refresh_all: when CC hangs,
      # terminate and restart rather than leaving the session idle at needs_input.
      auto_restart_session(process_pid)
    end
  end

  # Recover session when the Claude CLI process is still running
  # Enqueues a monitoring job to reconnect to the existing process
  def recover_with_running_process(process_pid)
    add_log("Claude CLI process #{process_pid} is still running", level: "verbose")
    add_log("Attempting to recover session by resuming monitoring of existing process", level: "info")

    # Enqueue recovery job and update running_job_id atomically
    recovery_job = AgentSessionJob.enqueue_for_monitoring(session.id, delay: 5.seconds)

    with_db_retry do
      session.update!(running_job_id: recovery_job.job_id)
    end

    add_log(
      "Recovery job enqueued (ActiveJob ID: #{recovery_job.job_id}) - monitoring will resume in 5 seconds",
      level: "info"
    )

    @logger.info("Recovered orphaned session with running process", process_pid: process_pid, job_id: recovery_job.job_id)
  end

  # Recover session when the Claude CLI process has stopped
  # Performs final transcript poll and transitions to needs_input
  # If there are enqueued messages, processes them instead of leaving session in needs_input
  def recover_with_stopped_process(process_pid)
    if process_pid
      add_log("Claude CLI process #{process_pid} has stopped", level: "verbose")
    end
    add_log("Process has stopped. Performing final transcript poll...", level: "verbose")

    # Poll transcript one last time to get any messages that weren't captured
    poller = TranscriptPollerService.new(session)
    poller.poll_and_broadcast

    add_log(
      "Recovered orphaned session but Claude Code session appears to have died. Session moved to needs_input status, awaiting user instruction.",
      level: "verbose"
    )

    transition_to_needs_input

    # Check for and process any enqueued messages before finishing
    # This ensures pending messages are not orphaned when recovery finds a stopped process
    processor = EnqueuedMessageProcessorService.new(session, log_buffer: @log_buffer)
    if processor.process_next_message
      add_log(
        "Enqueued message being processed after recovery",
        level: "info"
      )
      @logger.info("Processed enqueued message after recovery", process_pid: process_pid)
    else
      @logger.info("Moved orphaned session to needs_input", process_pid: process_pid, reason: "process_stopped")
    end
  end

  # Transition session to needs_input status and clear running_job_id
  def transition_to_needs_input
    with_db_retry do
      # Mark this as a recovery-initiated pause so refresh_all can auto-continue it.
      # User-initiated pauses have paused_by: "user" instead and won't be auto-continued.
      # Also clear recovery_termination_initiated since the recovery is complete.
      #
      # Strip pending_sleep BEFORE pausing. Recovery always intends to land the
      # session in needs_input so the auto-continue path can pick it up. If
      # pending_sleep lingers in metadata (set by the "auto-sleep on running
      # session" path, Trigger#sleep_target_session_if_applicable), the pause
      # callback's execute_pending_sleep would immediately transition the session
      # needs_input → waiting. But recovery registers no wake trigger, so the
      # session would be stranded in waiting forever — the auto-continue path only
      # rescues needs_input. Clearing the flag here keeps recovery deterministic.
      session.update!(
        running_job_id: nil,
        metadata: (session.metadata || {})
          .except("recovery_termination_initiated", "pending_sleep")
          .merge("paused_by" => "recovery")
      )
      session.pause! if session.may_pause?
    end
  end

  # Auto-restart a session after hung process recovery by sending the system recovery prompt.
  # Validates the session has the required metadata (session_id, working_directory) and
  # enqueues a new job to resume. Falls back to leaving session at needs_input if restart fails.
  def auto_restart_session(process_pid)
    # Validate session can be restarted
    unless session.session_id.present?
      add_log("Cannot auto-restart after hung process: no session_id found", level: "warning")
      @logger.info("Skipped auto-restart - no session_id", process_pid: process_pid)
      return
    end

    working_directory = session.metadata&.dig("working_directory")
    unless working_directory.present? && Dir.exist?(working_directory)
      add_log("Cannot auto-restart after hung process: working directory not found", level: "warning")
      @logger.info("Skipped auto-restart - working directory missing", process_pid: process_pid)
      return
    end

    with_db_retry do
      ActiveRecord::Base.transaction do
        add_log("Auto-restarting session after hung process termination", level: "info")

        # Clear stale retry metadata before restarting.
        # See Session::STALE_RETRY_METADATA_KEYS for the full list of keys cleared.
        session.update!(
          running_job_id: nil,
          metadata: (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)
        )
        session.resume! if session.may_resume?

        AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)

        add_log("Session auto-restarted after hung process recovery", level: "info")
      end
    end

    @logger.info("Auto-restarted session after hung process termination", process_pid: process_pid)
  rescue => e
    # If auto-restart fails, leave session at needs_input for manual intervention
    add_log("Failed to auto-restart session: #{e.message}", level: "error")
    @logger.error("Failed to auto-restart after hung process", process_pid: process_pid, error: e.message)
  end

  # Add log entry to session
  # Uses log_buffer if available, otherwise creates log directly
  def add_log(content, level: "info")
    if @log_buffer
      @log_buffer.add(content, level: level)
    else
      with_db_retry do
        session.logs.create!(content: content, level: level)
      end
    end
  end
end
