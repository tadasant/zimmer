# ProcessLifecycleManager - Centralized process lifecycle management
#
# This service encapsulates all process lifecycle decisions including spawn, monitor,
# terminate, and retry logic. It provides a clear state machine with mutex protection
# to prevent race conditions between the controller and job.
#
# State Machine:
#   idle -> spawning -> running -> terminating -> terminated
#        \-----------> running (on resume monitoring)
#        \-----------> handling_exit (during exit processing)
#
# Usage:
#   manager = ProcessLifecycleManager.new(
#     session: session,
#     cli_adapter: ClaudeCliAdapter.new,
#     process_manager: SystemProcessManager.new,
#     log_buffer: log_buffer
#   )
#
#   # Spawn a new process
#   result = manager.spawn(prompt: "Hello", working_dir: "/path/to/dir")
#   result.success? # => true
#   result.pid      # => 12345
#
#   # Check process status
#   manager.running? # => true
#   manager.state    # => :running
#
#   # Handle process exit
#   decision = manager.handle_exit(status, stderr_log_path: "/path/to/stderr.log")
#   decision.action # => :retry, :needs_input, :failed, :continue
#
#   # Terminate process
#   result = manager.terminate(reason: :user_pause)
#   result.success? # => true
#
# Benefits:
# - Single source of truth for process state
# - Thread-safe state transitions via mutex
# - Clear interface between controller/job/manager
# - Testable state machine
# - Natural place for retry logic and race condition handling
#
# This service is integrated into AgentSessionJob and SessionsController to provide
# centralized, thread-safe process lifecycle management.
#
# Retry Limits:
# - SIGTERM retries: MAX 3 attempts (via SigtermRetryService)
# - Context length compaction: MAX 2 attempts (via ContextLengthRetryService)
#
class ProcessLifecycleManager
  include DatabaseRetry

  # Process lifecycle states
  # - :idle - No process, ready for spawn
  # - :spawning - Process spawn in progress
  # - :running - Process is running
  # - :handling_exit - Processing exit decision (prevents concurrent spawns)
  # - :terminating - Termination in progress
  # - :terminated - Process was terminated
  STATES = %i[idle spawning running handling_exit terminating terminated].freeze

  # Number of status confirmation checks when detecting potential race condition
  # Provides ~600ms window for DB transaction to become visible
  STATUS_CONFIRMATION_CHECKS = 3

  # Delay between status confirmation checks (in seconds)
  STATUS_CONFIRMATION_DELAY = 0.2

  # Number of trailing stderr lines surfaced to the session log on a failure.
  # Enough to capture the operative error without dumping an unbounded log.
  STDERR_TAIL_LINES = 20

  # Maximum resume attempts after an abnormal signal death (SIGKILL/SIGSEGV/etc.),
  # e.g. an OOM kill of a long-running session. Mirrors SigtermRetryService's
  # MAX_RETRIES. The counter is reset by AgentSessionJob once a resumed process
  # runs stably (SIGTERM_RETRY_RESET_THRESHOLD), so a genuinely long-lived session
  # that OOMs occasionally gets a fresh budget each time rather than accumulating
  # toward a permanent failure over its lifetime.
  MAX_SIGNAL_DEATH_RETRIES = 3

  # Result structures
  SpawnResult = Struct.new(:success, :pid, :stderr_log_path, :error, keyword_init: true) do
    def success?
      success == true
    end
  end

  TerminateResult = Struct.new(:success, :reason, :error, keyword_init: true) do
    def success?
      success == true
    end
  end

  ExitDecision = Struct.new(:action, :retry_prompt, :error_message, keyword_init: true) do
    # Actions: :continue (new process spawned), :needs_input, :failed, :aborted
    def should_continue?
      action == :continue
    end
  end

  attr_reader :session, :cli_adapter, :process_manager, :log_buffer, :file_system,
              :state, :current_pid, :stderr_log_path

  def initialize(session:, cli_adapter: nil, process_manager: nil, log_buffer: nil, file_system: nil,
                 rate_limit_tracker: nil)
    @session = session
    # Select the CLI adapter from the session's runtime bundle when one isn't
    # explicitly injected (tests inject mocks). Without this, every session —
    # including Codex — would spawn the Claude CLI. claude_code/nil resolve to
    # ClaudeCliAdapter (or PtyClaudeCliAdapter when the pty_transport extension is
    # enabled), preserving existing behavior byte-for-byte when it is disabled.
    @cli_adapter = cli_adapter || RuntimeRegistry.cli_adapter_class_for(session&.agent_runtime).new
    @process_manager = process_manager || SystemProcessManager.new
    @log_buffer = log_buffer
    @file_system = file_system || RealFileSystemAdapter.new
    @rate_limit_tracker = rate_limit_tracker || GlobalRateLimitTracker.new

    # Ensure cli_adapter uses the same process_manager and file_system
    @cli_adapter.process_manager = @process_manager
    @cli_adapter.file_system = @file_system

    # Set the Zimmer session ID on the CLI adapter so every process it spawns (fresh
    # start, resume, and all recovery/retry respawns) injects ELICITATION_SESSION_ID
    # and AO_SESSION_SCRATCH_DIR into the child env. This MUST live in the constructor,
    # not #spawn: the resume_monitoring path never calls #spawn, yet a process it
    # monitors can exit and route through handle_exit into a respawn (spawn_continuation,
    # handle_failed_resume_recovery, or a retry service reusing this adapter). If the id
    # were only set in #spawn, those respawned MCP servers would post elicitations with a
    # blank session-id and get a 404 "Session not found" from the elicitation endpoint.
    @cli_adapter.zimmer_session_id = session.id

    @mutex = Mutex.new
    @state = :idle
    @current_pid = nil
    @stderr_log_path = nil
    @append_system_prompt = nil

    @logger = StructuredLogger.new({
      session_id: session.id,
      service: "ProcessLifecycleManager"
    })
  end

  # Spawn a new Claude CLI process
  #
  # @param prompt [String, nil] The prompt to send (nil for resume without prompt)
  # @param working_dir [String] The working directory
  # @param mcp_config_path [String, nil] Path to MCP config file
  # @param images [Array<Hash>, nil] Array of image data hashes with :path, :media_type keys
  # @param append_system_prompt [String, nil] Additional system prompt to append to Claude's defaults
  # @param model [String, nil] Model to use (e.g., "opus", "sonnet")
  # @param resume [Boolean] Whether to resume existing session
  # @return [SpawnResult] Result of spawn operation
  def spawn(prompt:, working_dir:, mcp_config_path: nil, images: nil, append_system_prompt: nil, model: nil, resume: false)
    @mutex.synchronize do
      # Only allow spawn from idle state (not handling_exit, running, etc.)
      unless @state == :idle
        return SpawnResult.new(success: false, error: "Cannot spawn: state is #{@state}")
      end

      @state = :spawning
    end

    begin
      # Store the system prompt and model for reuse in continuations (compact, retry, etc.)
      @append_system_prompt = append_system_prompt
      @model = model

      spawn_result = if resume
        @cli_adapter.resume(
          session_id: session.session_id,
          prompt: prompt,
          images: images,
          working_dir: working_dir,
          mcp_config_path: mcp_config_path,
          append_system_prompt: append_system_prompt,
          model: model,
          auto_compact_window: session.auto_compact_window
        )
      else
        @cli_adapter.execute(
          prompt: prompt,
          session_id: session.session_id,
          working_dir: working_dir,
          mcp_config_path: mcp_config_path,
          images: images,
          append_system_prompt: append_system_prompt,
          model: model,
          auto_compact_window: session.auto_compact_window
        )
      end

      @mutex.synchronize do
        @current_pid = spawn_result[:pid]
        @stderr_log_path = spawn_result[:stderr_log_path]
        @state = :running
      end

      add_log("Process spawned with PID #{@current_pid}", level: "info")
      @logger.info("Process spawned", pid: @current_pid, resume: resume)

      SpawnResult.new(
        success: true,
        pid: @current_pid,
        stderr_log_path: @stderr_log_path
      )
    rescue => e
      @mutex.synchronize { @state = :idle }
      add_log("Failed to spawn process: #{e.message}", level: "error")
      @logger.error("Failed to spawn process", error: e.message)
      SpawnResult.new(success: false, error: e.message)
    end
  end

  # Resume monitoring an existing process (used for session recovery)
  #
  # @param pid [Integer] Process ID to monitor
  # @param stderr_log_path [String, nil] Path to stderr log
  # @return [SpawnResult] Result indicating if monitoring was established
  def resume_monitoring(pid:, stderr_log_path: nil)
    @mutex.synchronize do
      return SpawnResult.new(success: false, error: "Cannot resume monitoring: state is #{@state}") unless @state == :idle

      unless @process_manager.running?(pid)
        return SpawnResult.new(success: false, error: "Process #{pid} is not running")
      end

      @current_pid = pid
      @stderr_log_path = stderr_log_path
      @state = :running
    end

    add_log("Resumed monitoring of process #{pid}", level: "info")
    @logger.info("Resumed monitoring", pid: pid)

    SpawnResult.new(success: true, pid: pid, stderr_log_path: stderr_log_path)
  end

  # Terminate the current process
  #
  # @param reason [Symbol] Reason for termination (:user_pause, :follow_up, :archive, :error)
  # @return [TerminateResult] Result of termination
  def terminate(reason:)
    pid_to_terminate = nil

    @mutex.synchronize do
      return TerminateResult.new(success: true, reason: :no_process) unless @current_pid
      return TerminateResult.new(success: false, error: "Cannot terminate: state is #{@state}") if @state == :terminating

      @state = :terminating
      pid_to_terminate = @current_pid
    end

    add_log("Terminating process #{pid_to_terminate} (reason: #{reason})", level: "info")

    termination_service = ProcessTerminationService.new(
      process_pid: pid_to_terminate,
      process_manager: @process_manager,
      log_buffer: @log_buffer,
      session: @session
    )
    result = termination_service.terminate

    @mutex.synchronize do
      @state = :terminated
      @current_pid = nil
    end

    @logger.info("Process terminated", pid: pid_to_terminate, reason: reason, status: result.status)

    TerminateResult.new(success: result.success?, reason: reason)
  end

  # Handle process exit and determine next action
  #
  # This method analyzes the exit status and stderr logs to determine the
  # appropriate recovery action (retry, needs_input, or failed).
  #
  # Thread safety: This method transitions to :handling_exit state while
  # processing, which prevents concurrent spawn attempts. The state will
  # transition to :idle (for needs_input/failed/aborted) or :running
  # (if retry spawned a new process).
  #
  # @param status [Process::Status] Exit status from Process.wait
  # @param working_dir [String] Working directory for spawning retry
  # @return [ExitDecision] Decision on what to do next
  def handle_exit(status, working_dir:)
    # Transition to handling_exit state to prevent concurrent spawn/terminate
    @mutex.synchronize do
      @state = :handling_exit
      @current_pid = nil
    end

    begin
      # Check session status before making retry decisions
      session.reload
      unless session.running?
        add_log("Session no longer running (status: #{session.status}), skipping exit handling", level: "info")
        @mutex.synchronize { @state = :idle }
        return ExitDecision.new(action: :aborted)
      end

      # Check if this exit was triggered by prompt-too-long hang detection.
      # The monitoring loop terminated the process after detecting the hung state,
      # so we route directly to compact recovery regardless of exit status.
      if session.metadata&.dig("prompt_too_long_hang_detected")
        with_db_retry do
          session.update!(
            metadata: session.metadata.except("prompt_too_long_hang_detected")
          )
        end
        add_log("Routing to compact recovery after 'Prompt is too long' hang detection", level: "info")
        return handle_context_length_error(working_dir)
      end

      # Success case - process completed normally
      # Every runtime exits 0 for a successful completion. Some runtimes also use a
      # specific non-zero code to mean "turn finished, awaiting input" rather than
      # failure (Claude Code exits 1 in that case; Codex does not). The runtime's
      # retry strategy owns that convention via #normal_completion_exit? so this
      # classifier is runtime-aware instead of hardcoding `exitstatus == 1`.
      if status.success? || retry_strategy.normal_completion_exit?(status)
        # Check if this was a /compact command that needs automatic continuation
        # When the /compact process completes successfully, we should automatically
        # continue with the user's task instead of waiting for manual input
        if session.metadata&.dig("pending_compact_continuation")
          return handle_compact_continuation(working_dir)
        end

        # Check for context length errors - route to compact/retry system
        if retry_strategy.context_length_error?(stderr_log_path: @stderr_log_path)
          add_log("Context length error detected on successful exit - attempting compact recovery", level: "info")
          return handle_context_length_error(working_dir)
        end

        # Check for a rotation-induced "Not logged in / Please run /login" auth
        # failure — the active account was rotated out from under this in-flight
        # session, invalidating its on-disk credentials. Recoverable: refresh the
        # identity and resume. Checked BEFORE the API-error path because the auth
        # error is recorded the same way (isApiErrorMessage: true); placing it
        # first lets "most recent error wins" route a fresh auth failure here even
        # if an older retryable 5xx is also present.
        if retry_strategy.auth_recovery_needed?(working_dir: working_dir)
          add_log("Not logged in detected on successful exit - attempting auth recovery", level: "info")
          return handle_auth_recovery(working_dir)
        end

        # Check for API server errors (500, 529, etc.) - retry with exponential backoff
        if retry_strategy.api_error_for_retry?(working_dir: working_dir)
          add_log("API server error detected on successful exit - attempting retry with backoff", level: "info")
          return handle_retryable_api_error(working_dir)
        end

        # Check for failed resume - Claude CLI exits 0 even when it can't find the
        # session to resume, producing "No conversation found with session ID" in stderr.
        # Instead of permanently failing, attempt to recover by starting a fresh CLI
        # session with the original prompt. This handles deploy-interrupt recovery where
        # the CLI session was too short-lived to persist on Anthropic's servers.
        # (Runtimes that signal a failed resume with a NON-zero exit — e.g. Codex —
        # are caught by the matching check in the failure branch below.)
        if retry_strategy.failed_resume_recovery_needed?(stderr_log_path: @stderr_log_path)
          add_log("Resume failed: runtime session no longer exists. Attempting fresh start recovery.", level: "warning")
          return handle_failed_resume_recovery(working_dir)
        end

        add_log("Process exited successfully", level: "info")

        @mutex.synchronize { @state = :idle }
        return ExitDecision.new(action: :needs_input)
      end

      # Recovery-initiated termination: the CleanupOrphanedSessionsJob killed this
      # process because it appeared hung. The recovery service set a metadata flag
      # before killing, so we abort here and let the recovery service handle the
      # transition to needs_input. Without this check, we'd race: this code path
      # would transition to failed while recovery tries to transition to needs_input.
      # This check must come before SIGTERM/context-length checks because the
      # ProcessTerminationService tries SIGTERM before escalating to SIGKILL,
      # so the process may exit with either signal.
      if session.metadata&.dig("recovery_termination_initiated")
        add_log("Process exit was recovery-initiated (hung process termination), deferring to recovery service", level: "info")
        @mutex.synchronize { @state = :idle }
        return ExitDecision.new(action: :aborted)
      end

      # Failed-resume recovery for runtimes that signal a missing/expired resume
      # target with a NON-zero exit. Codex's `exec resume <thread-id>` exits 1 with
      # a "no rollout found ... -32600" stderr when the rollout is gone. The Claude
      # path catches its failed resume in the success branch above (Claude exits 0);
      # this branch catches runtimes that exit non-zero. Both route to the same
      # fresh-start recovery so a vanished resume target restarts the turn instead of
      # being reported as a hard failure with a blank transcript.
      if retry_strategy.failed_resume_recovery_needed?(stderr_log_path: @stderr_log_path)
        add_log("Resume failed: runtime session no longer exists. Attempting fresh start recovery.", level: "warning")
        return handle_failed_resume_recovery(working_dir)
      end

      # SIGTERM case - may need retry
      if sigterm_exit?(status)
        return handle_sigterm_exit(working_dir)
      end

      # Context length error case
      if retry_strategy.context_length_error?(stderr_log_path: @stderr_log_path)
        return handle_context_length_error(working_dir)
      end

      # Rotation-induced auth failure ("Not logged in / Please run /login").
      # Checked before the API-error path for the same most-recent-error-wins
      # reason as in the success branch above.
      if retry_strategy.auth_recovery_needed?(working_dir: working_dir)
        return handle_auth_recovery(working_dir)
      end

      # API server error case (500, 529, etc.) - retry with exponential backoff
      if retry_strategy.api_error_for_retry?(working_dir: working_dir)
        return handle_retryable_api_error(working_dir)
      end

      # Abnormal signal death (SIGKILL/9, SIGSEGV/11, SIGBUS/7, …) — most commonly a
      # cgroup OOM kill of a long-running, large-transcript session. Unlike SIGTERM
      # (a graceful deploy/shutdown ask) this is an unexpected, external kill. Left
      # to fall through, it would surface as a scary terminal `failed` and only get
      # picked up ~15 min later by the generic stuck-session sweep. Instead we resume
      # the existing session immediately with a bounded retry budget, so a heartbeat/
      # long-running orchestrator survives an OOM the way it already survives SIGTERM.
      #
      # Placed LAST among the recovery branches (after the stderr-driven context-
      # length/auth/API-error checks) so a signaled exit that ALSO carries a more
      # specific, recoverable stderr condition still routes to that specific handler —
      # only a "pure" signal death (no matching stderr condition) resumes here.
      #
      # This never hijacks an AO-initiated termination: a user pause / ownership
      # supersede / timeout kill never reaches handle_exit (those paths return without
      # calling it), the session.running? guard at the top short-circuits a status
      # change, and the hung-process terminator's SIGTERM→SIGKILL escalation is caught
      # by the recovery_termination_initiated check above. A signal reaching here is
      # therefore genuinely external.
      if signal_death_exit?(status)
        return handle_signal_death(status, working_dir)
      end

      # General failure case
      error_msg = exit_status_description(status)
      add_log("Process failed with #{error_msg}", level: "error")
      surface_stderr_to_session_log
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :failed, error_message: error_msg)
    rescue => e
      # Ensure we return to idle state on any error
      @mutex.synchronize { @state = :idle }
      raise
    end
  end

  # Check if the process is currently running
  #
  # @return [Boolean] true if process is running
  def running?
    @mutex.synchronize do
      return false unless @state == :running && @current_pid
      @process_manager.running?(@current_pid)
    end
  end

  # Wait for process exit (non-blocking)
  #
  # @return [Array, nil] [pid, status] if process exited, nil otherwise
  def wait_nonblock
    pid = @mutex.synchronize { @current_pid }
    return nil unless pid

    begin
      @process_manager.wait(pid, Process::WNOHANG)
    rescue Errno::ECHILD
      # Not our child - use signal-based detection
      nil
    end
  end

  # Get current state
  #
  # @return [Symbol] Current lifecycle state
  def current_state
    @mutex.synchronize { @state }
  end

  private

  # Handle SIGTERM exit with potential retry
  #
  # Note: Called while in :handling_exit state. Must transition to :running
  # on success or :idle on failure/abort before returning.
  def handle_sigterm_exit(working_dir)
    # Wait briefly and re-check session status to avoid race condition
    unless wait_and_confirm_still_running
      add_log("Session status changed during SIGTERM handling, aborting retry", level: "info")
      @mutex.synchronize { @state = :idle }
      return ExitDecision.new(action: :aborted)
    end

    # Use SigtermRetryService for retry logic
    retry_service = SigtermRetryService.new(
      session,
      cli_adapter: @cli_adapter,
      process_manager: @process_manager,
      log_buffer: @log_buffer,
      rate_limit_tracker: @rate_limit_tracker,
      file_system: @file_system
    )

    retry_result = retry_service.attempt_retry(working_dir)

    case retry_result
    when :success
      # Update our state to reflect the new process spawned by retry service
      # We must sync state immediately to prevent race conditions
      @mutex.synchronize do
        # Reload session to get the PID stored by retry service
        session.reload
        @current_pid = session.metadata&.dig("process_pid")
        @stderr_log_path = File.join(session.metadata&.dig("clone_path") || "", "claude_stderr.log")
        @state = :running
      end
      ExitDecision.new(action: :continue)
    when :exhausted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :failed, error_message: "SIGTERM retry limit exhausted")
    when :aborted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :aborted)
    end
  end

  # Handle an abnormal signal death (SIGKILL/SIGSEGV/etc.) by resuming the session.
  #
  # Bounded by MAX_SIGNAL_DEATH_RETRIES. Each attempt resumes the existing runtime
  # session id (via spawn_continuation) with the SYSTEM_RECOVERY prompt so the agent
  # picks up where it left off. AgentSessionJob resets signal_death_retry_count once
  # a resumed process runs stably, so this is a per-incident budget, not a lifetime
  # cap. Per the logging philosophy, intermediate attempts log at .info; we only
  # escalate to .warning (and a terminal :failed) once the budget is exhausted.
  #
  # Note: Called while in :handling_exit state. Must transition to :running
  # on success or :idle on failure/abort before returning.
  #
  # @param status [Process::Status] The signal-death exit status
  # @param working_dir [String] Working directory for spawning the resume
  # @return [ExitDecision] Decision on what to do next
  def handle_signal_death(status, working_dir)
    signal_desc = exit_status_description(status)
    retry_count = session.metadata&.dig("signal_death_retry_count").to_i

    if retry_count >= MAX_SIGNAL_DEATH_RETRIES
      add_log(
        "Process killed by #{signal_desc} and signal-death resume limit reached " \
        "(#{MAX_SIGNAL_DEATH_RETRIES} attempts) — failing session",
        level: "warning"
      )
      @logger.warn("Signal-death resume limit exhausted", signal: signal_desc, attempts: retry_count)
      surface_stderr_to_session_log
      @mutex.synchronize { @state = :idle }
      return ExitDecision.new(
        action: :failed,
        error_message: "Signal death resume limit exhausted (last: #{signal_desc})"
      )
    end

    # Re-confirm the session is still running to avoid racing a user pause/archive.
    unless wait_and_confirm_still_running
      add_log("Session status changed during signal-death handling, aborting resume", level: "info")
      @mutex.synchronize { @state = :idle }
      return ExitDecision.new(action: :aborted)
    end

    next_attempt = retry_count + 1
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge(
          "signal_death_retry_count" => next_attempt,
          "last_signal_death_at" => Time.current.iso8601
        )
      )
    end

    add_log(
      "Process killed by #{signal_desc} (likely OOM or external kill) — resuming session " \
      "(attempt #{next_attempt}/#{MAX_SIGNAL_DEATH_RETRIES})",
      level: "info"
    )
    @logger.info("Recovering from signal death", signal: signal_desc, attempt: next_attempt)

    # spawn_continuation resumes the existing runtime session id and handles its own
    # state transitions + error rescue (returning :failed if the resume itself fails).
    # A resume that lands on a vanished conversation is caught on the next loop by the
    # failed_resume_recovery path, which restarts fresh from the original prompt.
    spawn_continuation(
      working_dir: working_dir,
      prompt: AutomatedPrompts::SYSTEM_RECOVERY,
      reason: "signal death (#{signal_desc})"
    )
  end

  # Handle context length error with /compact retry
  #
  # Note: Called while in :handling_exit state. Must transition to :running
  # on success or :idle on failure/abort before returning.
  def handle_context_length_error(working_dir)
    compact_service = ContextLengthRetryService.new(
      session,
      cli_adapter: @cli_adapter,
      process_manager: @process_manager,
      log_buffer: @log_buffer,
      file_system: @file_system
    )

    compact_result = compact_service.attempt_recovery(working_dir, @stderr_log_path)

    case compact_result
    when :success
      # Update our state to reflect the new process spawned by compact service
      # We must sync state immediately to prevent race conditions
      @mutex.synchronize do
        # Reload session to get the PID stored by compact service
        session.reload
        @current_pid = session.metadata&.dig("process_pid")
        @stderr_log_path = File.join(session.metadata&.dig("clone_path") || "", "claude_stderr.log")
        @state = :running
      end
      ExitDecision.new(action: :continue)
    when :exhausted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :failed, error_message: "Context length compact limit exhausted")
    when :aborted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :aborted)
    else
      # :not_applicable shouldn't happen since we checked retry_strategy.context_length_error? first
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :failed, error_message: "Context length error recovery failed")
    end
  end

  # Handle automatic continuation after successful /compact command
  #
  # When /compact completes successfully, the session should automatically continue
  # with a follow-up prompt instead of transitioning to needs_input and waiting
  # for manual user intervention. This provides a seamless recovery experience.
  #
  # Note: Called while in :handling_exit state. Must transition to :running
  # on success or :idle on failure/abort before returning.
  #
  # @param working_dir [String] Working directory for spawning continuation
  # @return [ExitDecision] Decision on what to do next
  def handle_compact_continuation(working_dir)
    add_log("Compact completed successfully, automatically continuing with task", level: "info")

    # Clear the pending continuation flag and context length tracking before spawning
    # We reset context_length_last_checked_line so that if a NEW context length error
    # occurs during the continuation, it will be detected and handled appropriately.
    # Without this reset, we might miss new errors that occur after compact succeeded.
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).except(
          "pending_compact_continuation",
          "context_length_last_checked_line",
          "prompt_too_long_hang_detected_at_line",
          "prompt_too_long_hang_detected"
        )
      )
    end

    spawn_continuation(
      working_dir: working_dir,
      prompt: "Continue with the previous task",
      reason: "compact"
    )
  end

  # Spawn a continuation process with the given prompt
  #
  # Handles CLI resume call, PID tracking, state transitions, and error handling
  # for compact continuation.
  #
  # @param working_dir [String] Working directory for spawning continuation
  # @param prompt [String] The continuation prompt to send
  # @param reason [String] Human-readable reason for logging (e.g., "compact")
  # @return [ExitDecision] Decision on what to do next
  def spawn_continuation(working_dir:, prompt:, reason:)
    # Guard: the session's clone directory can be removed out from under us by the
    # clone GC (DeferredCloneCleanupJob/StaleCloneCleanupJob) once the session is
    # torn down — a routine, expected condition. If that has happened, resuming is
    # impossible (the CLI adapter would raise Errno::ENOENT opening claude_stderr.log
    # under the deleted path, wrapped as ClaudeCliError). That is NOT broken system
    # behavior, so we terminate gracefully at warn level rather than tripping the
    # error-log alert. Genuine spawn failures — where the directory exists but the
    # CLI still fails to launch — fall through to the rescue below and stay at error.
    unless @file_system.directory?(working_dir)
      add_log(
        "Cannot continue after #{reason}: clone directory no longer exists (#{working_dir}) — session already torn down",
        level: "warning"
      )
      @logger.warn(
        "#{reason.capitalize} continuation skipped — clone directory no longer exists",
        working_dir: working_dir
      )
      @mutex.synchronize { @state = :idle }
      return ExitDecision.new(
        action: :failed,
        error_message: "Clone directory no longer exists — cannot continue after #{reason}"
      )
    end

    spawn_result = @cli_adapter.resume(
      session_id: session.session_id,
      prompt: prompt,
      working_dir: working_dir,
      append_system_prompt: @append_system_prompt,
      model: @model,
      auto_compact_window: session.auto_compact_window
    )

    new_pid = spawn_result[:pid]

    add_log(
      "Spawned continuation process with PID #{new_pid}",
      level: "info"
    )

    # Update session metadata with new process PID
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge("process_pid" => new_pid)
      )
    end

    # Update our state to reflect the new process
    @mutex.synchronize do
      @current_pid = new_pid
      @stderr_log_path = File.join(session.metadata&.dig("clone_path") || "", "claude_stderr.log")
      @state = :running
    end

    @logger.info("#{reason.capitalize} continuation successful", new_pid: new_pid)

    ExitDecision.new(action: :continue)
  rescue => e
    add_log("Failed to continue after #{reason}: #{e.message}", level: "error")
    @logger.error("#{reason.capitalize} continuation failed", error: e.message)
    @mutex.synchronize { @state = :idle }
    ExitDecision.new(action: :failed, error_message: "Failed to continue after #{reason}: #{e.message}")
  end

  # Handle recovery from a failed --resume attempt by starting fresh with --session-id.
  #
  # When Claude CLI can't find a session to resume (e.g., the original process was
  # killed before the conversation persisted on Anthropic's servers), we recover by:
  # 1. Resetting runtime_started so the next spawn uses --session-id instead of --resume
  # 2. Spawning a fresh CLI process with the session's original prompt
  #
  # This commonly happens during deploy-interrupt recovery: the original session barely
  # started (e.g., 1 transcript line), got killed by GoodJob shutdown, and the auto-recovery
  # tried to --resume a session that never persisted.
  #
  # Falls back to permanent failure if there's no original prompt to retry with.
  #
  # No retry counter needed (unlike SIGTERM/compact/API error handlers) because
  # the recovery uses execute (--session-id), not resume (--resume). A successful
  # fresh start won't re-trigger failed_resume_recovery_needed?, and a failed spawn returns :failed
  # immediately — so there's no loop risk.
  #
  # Note: Called while in :handling_exit state. Must transition to :running
  # on success or :idle on failure before returning.
  #
  # @param working_dir [String] Working directory for spawning fresh process
  # @return [ExitDecision] Decision on what to do next
  def handle_failed_resume_recovery(working_dir)
    session.reload

    # Prefer the user's pending follow-up message over the original session prompt.
    # When a --resume fails (e.g. the clone was recreated so the local transcript is
    # gone), we restart fresh — but if the user just sent a follow-up, that message
    # is what they're waiting on, not the original task. `sent_message` holds the
    # pending follow-up until it appears in the transcript; it is absent for the
    # deploy-interrupt case this recovery was first built for (a barely-started
    # session with no follow-up), where we correctly fall back to session.prompt.
    # Without this, a follow-up whose resume fails silently re-runs the original task
    # and the user's message is dropped — the session bounces straight back to
    # needs_input with no visible action.
    recovery_prompt = session.metadata&.dig("sent_message").presence || session.prompt

    unless recovery_prompt.present?
      error_msg = "Resume failed and no prompt available for fresh start recovery"
      add_log(error_msg, level: "error")
      @mutex.synchronize { @state = :idle }
      return ExitDecision.new(action: :failed, error_message: error_msg)
    end

    # Reset runtime_started so future spawns use --session-id instead of --resume
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge("runtime_started" => false)
      )
    end

    add_log("Recovering from failed resume: starting fresh CLI session with original prompt", level: "info")
    @logger.info("Failed resume recovery: spawning fresh CLI session")

    # Reconstruct mcp_config_path if the session uses MCP servers (including
    # auto-injected self-session servers) — without this, the recovered session
    # would silently lose MCP server access.
    mcp_config_path = if session.all_mcp_servers.present?
      File.join(working_dir, ".mcp.json")
    end

    spawn_result = @cli_adapter.execute(
      prompt: recovery_prompt,
      session_id: session.session_id,
      working_dir: working_dir,
      mcp_config_path: mcp_config_path,
      append_system_prompt: @append_system_prompt,
      model: @model,
      auto_compact_window: session.auto_compact_window
    )

    new_pid = spawn_result[:pid]

    add_log("Fresh start recovery successful, spawned PID #{new_pid}", level: "info")

    # Update session metadata with new process PID and re-set runtime_started
    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge(
          "process_pid" => new_pid,
          "runtime_started" => true
        )
      )
    end

    # Update our state to reflect the new process
    @mutex.synchronize do
      @current_pid = new_pid
      @stderr_log_path = File.join(session.metadata&.dig("clone_path") || "", "claude_stderr.log")
      @state = :running
    end

    @logger.info("Failed resume recovery successful", new_pid: new_pid)

    ExitDecision.new(action: :continue)
  rescue => e
    error_msg = "Failed resume recovery failed: #{e.message}"
    add_log(error_msg, level: "error")
    @logger.error("Failed resume recovery failed", error: e.message)
    @mutex.synchronize { @state = :idle }
    ExitDecision.new(action: :failed, error_message: error_msg)
  end

  # Wait briefly and re-check if session is still running
  #
  # This prevents race condition where user pauses but status update isn't visible yet.
  # We check multiple times with delays to allow DB transactions to become visible.
  #
  # Note: This method should only be called when the manager is in :handling_exit state,
  # where we're making retry decisions. The calling code must handle the false return
  # by setting state to :idle before returning.
  #
  # @return [Boolean] true if session is still running after all checks, false otherwise
  def wait_and_confirm_still_running
    STATUS_CONFIRMATION_CHECKS.times do |attempt|
      sleep(STATUS_CONFIRMATION_DELAY) if attempt > 0
      session.reload
      return false unless session.running?
    end
    true
  end

  # Check if process exited due to SIGTERM
  def sigterm_exit?(status)
    status.exitstatus == 143 || status.termsig == 15
  end

  # Check if the process was killed by an abnormal signal that is NOT SIGTERM.
  # SIGTERM has its own graceful-shutdown retry path (handle_sigterm_exit); this
  # catches everything else a kernel/external actor can throw at the process —
  # SIGKILL (9, OOM killer), SIGSEGV (11), SIGBUS (7), SIGABRT (6), etc.
  #
  # Matches both a raw signaled exit (status.signaled?, termsig set) AND the
  # shell/wrapper 128+N translation (exit code > 128), mirroring how sigterm_exit?
  # accepts both termsig 15 and exit 143. SIGTERM in either form is excluded so it
  # keeps its dedicated path. A normal exit (code <= 128, e.g. 0/1/2) is not a
  # signal death and takes the exit-code paths.
  def signal_death_exit?(status)
    return false if sigterm_exit?(status)
    return true if status.signaled?

    exitstatus = status.exitstatus
    exitstatus.present? && exitstatus > 128
  end

  # Surface the tail of the process's stderr to the session log on a genuine
  # failure so the user sees the actual error (e.g. a Codex "no rollout found"
  # message) instead of a blank turn. No-op when there is no stderr log or it is
  # empty. Failures here are non-fatal — they must never mask the failure itself.
  def surface_stderr_to_session_log
    return unless @stderr_log_path
    return unless @file_system.exists?(@stderr_log_path)

    content = @file_system.read(@stderr_log_path)
    return if content.blank?

    tail = content.strip.split("\n").last(STDERR_TAIL_LINES).join("\n")
    add_log("Process stderr:\n#{tail}", level: "error")
  rescue => e
    @logger.error("Failed to surface stderr to session log", error: e.message)
  end

  # Runtime-specific exit classifier supplied by the CLI adapter.
  #
  # The adapter owns the patterns that distinguish context-length errors,
  # failed resumes, and retryable API errors because they differ per runtime
  # (Claude vs. Codex, etc.). Generic, OS-level classification (e.g. SIGTERM)
  # stays here because it applies to every runtime.
  def retry_strategy
    @retry_strategy ||= @cli_adapter.retry_strategy(
      session: session,
      file_system: @file_system,
      process_manager: @process_manager,
      rate_limit_tracker: @rate_limit_tracker,
      logger: @logger
    )
  end

  # Handle API server error (500, 529, etc.) with exponential backoff retry
  #
  # Note: Called while in :handling_exit state. Must transition to :running
  # on success or :idle on failure/abort before returning.
  def handle_retryable_api_error(working_dir)
    # Wait briefly and re-check session status to avoid race condition
    unless wait_and_confirm_still_running
      add_log("Session status changed during API error handling, aborting retry", level: "info")
      @mutex.synchronize { @state = :idle }
      return ExitDecision.new(action: :aborted)
    end

    retry_service = ApiErrorRetryService.new(
      session,
      cli_adapter: @cli_adapter,
      process_manager: @process_manager,
      log_buffer: @log_buffer,
      file_system: @file_system,
      rate_limit_tracker: @rate_limit_tracker
    )

    retry_result = retry_service.attempt_retry(working_dir)

    case retry_result
    when :success
      @mutex.synchronize do
        session.reload
        @current_pid = session.metadata&.dig("process_pid")
        @stderr_log_path = File.join(session.metadata&.dig("clone_path") || "", "claude_stderr.log")
        @state = :running
      end
      ExitDecision.new(action: :continue)
    when :exhausted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :failed, error_message: "API error retry limit exhausted")
    when :quota_exceeded
      rotation_result = attempt_account_rotation(working_dir)
      return rotation_result if rotation_result

      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :needs_input, error_message: "Account quota limit reached and no other accounts available — retry skipped (resets at time shown in error)")
    when :aborted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :aborted)
    when :not_applicable
      # Shouldn't happen since we checked retry_strategy.api_error_for_retry? first, but handle gracefully
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :failed, error_message: "API server error recovery failed")
    end
  end

  # Handle a rotation-induced "Not logged in / Please run /login" auth failure by
  # refreshing the worker's on-disk identity to the current active account and
  # re-spawning. See AuthRecoveryService for the full recovery semantics.
  #
  # Note: Called while in :handling_exit state. Must transition to :running on
  # success or :idle on failure/abort before returning.
  def handle_auth_recovery(working_dir)
    # Wait briefly and re-check session status to avoid race condition
    unless wait_and_confirm_still_running
      add_log("Session status changed during auth recovery handling, aborting retry", level: "info")
      @mutex.synchronize { @state = :idle }
      return ExitDecision.new(action: :aborted)
    end

    recovery_service = AuthRecoveryService.new(
      session,
      cli_adapter: @cli_adapter,
      process_manager: @process_manager,
      log_buffer: @log_buffer,
      file_system: @file_system
    )

    result = recovery_service.attempt_recovery(working_dir)

    case result
    when :success
      @mutex.synchronize do
        session.reload
        @current_pid = session.metadata&.dig("process_pid")
        @stderr_log_path = File.join(session.metadata&.dig("clone_path") || "", "claude_stderr.log")
        @state = :running
      end
      ExitDecision.new(action: :continue)
    when :exhausted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :failed, error_message: "Auth recovery retry limit exhausted")
    when :unrecoverable
      # No valid account available to recover to — surface to the user (re-auth
      # needed) rather than failing silently or looping.
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :needs_input, error_message: "Not logged in and no valid account available to recover — re-authenticate an account to restore service")
    when :aborted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :aborted)
    when :not_applicable
      # Shouldn't happen since we checked retry_strategy.auth_recovery_needed? first, but handle gracefully
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :failed, error_message: "Auth recovery failed")
    end
  end

  # Attempt to rotate to a different account for the session's runtime after a
  # quota-exceeded exit. Returns an ExitDecision if rotation succeeded, nil if no
  # accounts available.
  def attempt_account_rotation(working_dir)
    provider = RuntimeAuthProvider.for(@session&.agent_runtime)
    result = provider.rotate_for_quota!(
      triggered_by: @session ? "session:#{@session.id}" : nil
    )

    return nil unless result[:success]

    add_log(
      "Account quota hit — rotated to #{result[:account].email}",
      level: "warning"
    )
    @log_buffer&.flush

    spawn_continuation(
      working_dir: working_dir,
      prompt: AutomatedPrompts::SYSTEM_RECOVERY,
      reason: "account rotation"
    )
  rescue => e
    @logger.error("Account rotation failed", error: e.message)
    add_log("Account rotation failed: #{e.message}", level: "error")
    nil
  end

  # Generate description for exit status
  def exit_status_description(status)
    if status.signaled? && status.termsig
      signal_name = Signal.signame(status.termsig) || "unknown"
      "signal: SIG#{signal_name} (#{status.termsig})"
    else
      "exit code: #{status.exitstatus}"
    end
  end

  # Add log entry
  def add_log(content, level: "info")
    if @log_buffer
      @log_buffer.add(content, level: level)
    elsif @session
      with_db_retry do
        @session.logs.create!(content: content, level: level)
      end
    else
      Rails.logger.send(level, "[ProcessLifecycleManager] #{content}")
    end
  end
end
