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

  # Maximum number of times a turn that ended with the runtime having written
  # NOTHING is restarted from scratch before the session is allowed to come to
  # rest. See #handle_empty_turn.
  #
  # No reset logic pairs with this counter, and none is needed: the branch fires
  # only while neither transcript store holds a byte, so a session that ever
  # produces output can never reach it again. A session still empty after two
  # restarts is not going to be fixed by a third.
  MAX_EMPTY_TURN_RECOVERIES = 2

  # Maximum number of times a fresh start that the runtime refused because the
  # session id was still held is retried under a newly minted id.
  MAX_SESSION_ID_CONFLICT_RECOVERIES = 2

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
              :state, :current_pid, :stderr_log_path, :owning_job_id

  def initialize(session:, cli_adapter: nil, process_manager: nil, log_buffer: nil, file_system: nil,
                 rate_limit_tracker: nil, owning_job_id: nil)
    @session = session
    # The ActiveJob id of the job supervising this session's turn, when there is one.
    # #handle_exit compares it against the session's running_job_id so a superseded job
    # does not answer its process's exit by spawning a replacement. Nil means "no owner
    # recorded" and disables that check, which is what a caller constructing a manager
    # outside a job (and every test that does not care) gets.
    @owning_job_id = owning_job_id
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
      # One session, one live agent process (zimmer#395).
      #
      # The job-level guard asks JobLiveness whether the *recorded job* is still
      # executing, and superseding a job nothing is executing is correct. But a job and
      # the process it spawned do not die together: a worker killed without running its
      # `ensure` leaves its agent process alive, and `process_pid` is a single slot that
      # the next spawn overwrites, so the handle to it is lost. So ask about the process
      # too. AgentProcessLiveness answers only when it can prove the pid belongs to this
      # namespace and is the same process we spawned; anything less certain is inert. It
      # terminates rather than refusing to spawn: this call carries the user's prompt, and
      # standing down here would trade a rare double-run for a silently dropped turn.
      #
      # #spawn is the right place for it, not #perform. Every NEW turn's process comes
      # through here, and only new turns: the resume-monitoring path deliberately
      # reconnects to the recorded process and calls #resume_monitoring instead, so a
      # check placed earlier in the job would terminate the very process that path exists
      # to adopt. One exception is knowingly swept up — an agent held alive across an MCP
      # elicitation (see the keep-alive branch in the job's monitoring loop) is terminated
      # like any other, losing the in-flight tool call. A new turn is arriving either way,
      # and two agents is the worse outcome.
      AgentProcessLiveness.ensure_no_live_process!(
        session,
        process_manager: @process_manager,
        log_buffer: @log_buffer
      )

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
  # @param verify_identity [Boolean] whether to refuse a pid the session's recorded process
  #   identity disowns. Only the recovery path wants this. SessionsController calls this
  #   method purely to load the manager with a pid so #terminate can kill it, and there a
  #   refusal would skip the kill and orphan a live agent that keeps burning quota — so it
  #   defaults off and the caller that is adopting opts in.
  # @return [SpawnResult] Result indicating if monitoring was established
  def resume_monitoring(pid:, stderr_log_path: nil, verify_identity: false)
    @mutex.synchronize do
      return SpawnResult.new(success: false, error: "Cannot resume monitoring: state is #{@state}") unless @state == :idle

      unless @process_manager.running?(pid)
        return SpawnResult.new(success: false, error: "Process #{pid} is not running")
      end

      # `running?` is signal 0, which answers "some process holds this number", not "the
      # process we spawned is still there". In a container whose pids recycle quickly the
      # difference is the whole ballgame: a turn terminated seconds ago can have its
      # number reissued, and adopting it reports a recovery that did not happen. The
      # monitoring loop then reads that stranger's exit as this session's turn completing
      # and pauses to needs_input, discarding the turn Zimmer never actually delivered.
      #
      # #spawn's guard deliberately skips this path so it does not kill the process the
      # path exists to adopt. This is the read-only half of the same question: it refuses
      # to adopt, and never signals anything.
      if verify_identity && !AgentProcessLiveness.adoptable?(session, pid)
        return SpawnResult.new(
          success: false,
          error: "Process #{pid} is not the process this session spawned (exited, or its pid was recycled)"
        )
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

      # Ownership. Several branches below answer an exit by spawning a replacement
      # (SIGTERM retry, signal-death retry, compaction, API-error retry), and each is
      # right only while this job still owns the session's turn. Once another job has
      # taken ownership, the exit we are handling is very often one *it* caused —
      # `AgentProcessLiveness` terminating this turn's process before spawning its own is
      # exactly that — and respawning in answer to it puts a second agent back on the
      # clone the guard just cleared. The monitoring loop enforces the same invariant one
      # level up when it reloads the session; this enforces it at the point where the
      # decision to spawn is actually made. A nil `running_job_id` means "not superseded"
      # (a pause clears it), matching the loop's reading.
      if owning_job_id.present? && session.running_job_id.present? && session.running_job_id != owning_job_id
        add_log(
          "Session ownership moved to job #{session.running_job_id} (this job is #{owning_job_id}); " \
          "not answering this exit with a respawn",
          level: "info"
        )
        @mutex.synchronize { @state = :idle }
        return ExitDecision.new(action: :aborted)
      end

      # Check if this exit was triggered by prompt-too-long hang detection.
      # The monitoring loop terminated the process after detecting the hung state,
      # so we route directly to compact recovery regardless of exit status.
      if session.metadata&.dig("prompt_too_long_hang_detected")
        with_db_retry do
          session.remove_metadata!("prompt_too_long_hang_detected")
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
        # session with the best durable prompt. This handles deploy-interrupt recovery
        # where the CLI session was too short-lived to persist on Anthropic's servers.
        # (Runtimes that signal a failed resume with a NON-zero exit — e.g. Codex —
        # are caught by the matching check in the failure branch below.)
        if retry_strategy.failed_resume_recovery_needed?(stderr_log_path: @stderr_log_path)
          add_log("Resume failed: runtime session no longer exists. Attempting fresh start recovery.", level: "warning")
          return handle_failed_resume_recovery(working_dir)
        end

        # The runtime refused to start because the session id it was handed is
        # still held. Recoverable by minting a new one — see #handle_session_id_conflict.
        if session_id_conflict?
          return handle_session_id_conflict(working_dir)
        end

        # Last, because every branch above is a *specific* diagnosis and this one
        # is the catch-all: the process exited cleanly having written nothing at
        # all. That is never a completed turn, so drive the session forward
        # instead of parking it with an empty transcript for a human to notice.
        if empty_turn_recovery_needed?(working_dir)
          return handle_empty_turn(working_dir)
        end

        # The invariant that makes a silently-absorbed turn impossible: a turn
        # whose LAST conversational entry is an API error did not complete, no
        # matter how the runtime worded that error.
        #
        # Every branch above is a *specific* diagnosis matched against the
        # runtime's prose, and every one of them can go stale. This one asks a
        # structural question instead, and asks it LAST — so an answer here means
        # not one of those branches claimed a turn that plainly died. That covers
        # both halves of the failure: a wording nobody knows, and a wording some
        # classifier does know but has already spent its retry cursor on.
        #
        # This is the 2026-08-20 incident (session 6412): Claude Code recorded
        # `"error":"authentication_failed"` / "Failed to authenticate: OAuth
        # session expired and could not be refreshed", exited 1 — its
        # turn-finished convention — and Zimmer parked the session as `needs_input`
        # with "Process exited successfully", leaving a human's message unanswered
        # and nothing in the logs to find it by.
        if (terminal_error = unhandled_terminal_api_error(working_dir))
          return handle_terminal_api_error(terminal_error)
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

      # Same reasoning as the matching check in the success branch above, for a
      # runtime that reports a held session id with a non-zero exit.
      if session_id_conflict?
        return handle_session_id_conflict(working_dir)
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

      # General failure case — the unclassified branch.
      #
      # Every check above is a pattern match against the runtime's own prose or
      # exit convention. Reaching here means not one of them recognized this
      # death: it is not a normal completion, not a SIGTERM, not a signal death,
      # and neither stderr nor the transcript carries a context-length, auth,
      # failed-resume, or retryable-API signature. That is either a genuinely
      # novel failure or — the case that has actually bitten us — a classifier
      # that went stale when the CLI reworded a message.
      #
      # The session still fails exactly as before; the difference is that it no
      # longer does so quietly. See UnclassifiedFailureReporter.
      error_msg = exit_status_description(status)
      add_log("Process failed with #{error_msg}", level: "error")
      surface_stderr_to_session_log
      report_unclassified_exit(error_msg, working_dir)
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
        @stderr_log_path = rebuilt_stderr_log_path
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
      session.merge_metadata!(
        "signal_death_retry_count" => next_attempt,
        "last_signal_death_at" => Time.current.iso8601
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
    # failed_resume_recovery path, which restarts fresh from the best durable prompt.
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
        @stderr_log_path = rebuilt_stderr_log_path
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
      report_recovery_contradiction("handle_context_length_error", compact_result)
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
    # impossible (the CLI adapter would raise Errno::ENOENT opening its stderr log
    # under the deleted path, wrapped as its own spawn error). That is NOT broken system
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
      session.record_agent_process!(new_pid)
    end

    # Update our state to reflect the new process
    @mutex.synchronize do
      @current_pid = new_pid
      @stderr_log_path = spawn_result[:stderr_log_path]
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
  # killed before the conversation persisted on Anthropic's servers), we recover by
  # restarting the turn from scratch — see #fresh_start!.
  #
  # This commonly happens during deploy-interrupt recovery: the original session barely
  # started (e.g., 1 transcript line), got killed by GoodJob shutdown, and the auto-recovery
  # tried to --resume a session that never persisted.
  #
  # No retry counter needed (unlike SIGTERM/compact/API error handlers) because
  # the recovery uses execute (--session-id), not resume (--resume). A successful
  # fresh start won't re-trigger failed_resume_recovery_needed?, and a failed spawn returns :failed
  # immediately — so there's no loop risk.
  #
  # @param working_dir [String] Working directory for spawning fresh process
  # @return [ExitDecision] Decision on what to do next
  def handle_failed_resume_recovery(working_dir)
    fresh_start!(working_dir, reason: "failed resume")
  end

  # A turn ended with the runtime having written NOTHING — not one transcript
  # line — and every specific classifier said the exit was normal.
  #
  # That combination is never a completed turn. It is what a first-connect failure
  # looks like from here: something killed or refused the process before the agent
  # produced output, and the exit that followed carried no signature to classify.
  # Parking on it is how a five-second npm hiccup became a session that sat in
  # needs_input with a blank transcript until a human typed "continue" (prod
  # session 4668).
  #
  # So restart the turn instead, bounded by MAX_EMPTY_TURN_RECOVERIES. It is the
  # cause-agnostic backstop behind every specific recovery above it — but scoped to
  # a session that has NEVER produced a line, not to every empty turn: the question
  # it asks is about the session's whole transcript, so a later turn that happens to
  # write nothing still parks exactly as before. What it protects is a session that
  # never got going at all.
  #
  # Note: Called while in :handling_exit state. Must transition to :running
  # on success or :idle on failure before returning.
  def handle_empty_turn(working_dir)
    attempt = empty_turn_recovery_count + 1

    add_log(
      "Process exited without the runtime writing a single transcript line — restarting the turn " \
      "(attempt #{attempt}/#{MAX_EMPTY_TURN_RECOVERIES}) rather than leaving the session at rest with an empty transcript",
      level: "warning"
    )
    @logger.warn("Recovering from an empty turn", attempt: attempt)

    with_db_retry { session.merge_metadata!("empty_turn_recovery_count" => attempt) }

    fresh_start!(working_dir, reason: "empty turn")
  rescue => e
    # The counter write is the only thing here outside #fresh_start!'s own rescue.
    # A bookkeeping failure must park the session, not raise out of handle_exit.
    @logger.error("Empty-turn recovery failed", error: e.message)
    add_log("Could not restart the empty turn: #{e.message}", level: "error")
    @mutex.synchronize { @state = :idle }
    ExitDecision.new(action: :needs_input, error_message: "Empty-turn recovery failed: #{e.message}")
  end

  # The runtime refused to start because the session id it was handed is still
  # held ("Session ID … is already in use"). Claude reports that refusal with exit
  # code 1 — its "turn finished, awaiting input" convention — so without this
  # handler it is indistinguishable from a completed turn and parks the session.
  #
  # Two shapes, two recoveries. If a conversation for that id exists, the id is
  # held because there is something to resume, so resume it. If nothing has been
  # written, the holder is a process from an earlier attempt at this same turn that
  # outlived its job, and a new id costs nothing — #fresh_start! terminates such a
  # process before spawning, so this is the belt to that braces.
  #
  # Note: Called while in :handling_exit state. Must transition to :running
  # on success or :idle on failure before returning.
  def handle_session_id_conflict(working_dir)
    session.reload
    attempt = session.metadata&.dig("session_id_conflict_count").to_i + 1

    if attempt > MAX_SESSION_ID_CONFLICT_RECOVERIES
      add_log(
        "Runtime refused to start: session id #{session.session_id} is already in use, and the " \
        "recovery budget is spent (#{MAX_SESSION_ID_CONFLICT_RECOVERIES} attempts)",
        level: "error"
      )
      surface_stderr_to_session_log
      @mutex.synchronize { @state = :idle }
      return ExitDecision.new(action: :failed, error_message: "Runtime session id #{session.session_id} is already in use")
    end

    with_db_retry { session.merge_metadata!("session_id_conflict_count" => attempt) }

    if conversation_persisted?(working_dir)
      # The id names a real conversation. Minting a new one would abandon it;
      # resuming is what the refusal is actually telling us to do. Restore
      # runtime_started so the resume builds `--resume` rather than `--session-id`.
      add_log(
        "Runtime refused to start: session id #{session.session_id} is already in use and names an " \
        "existing conversation — resuming it instead (attempt #{attempt}/#{MAX_SESSION_ID_CONFLICT_RECOVERIES})",
        level: "warning"
      )
      @logger.warn("Resuming the conversation a held session id names", attempt: attempt)
      with_db_retry { session.merge_metadata!("runtime_started" => true) }

      return spawn_continuation(
        working_dir: working_dir,
        prompt: AutomatedPrompts::SYSTEM_RECOVERY,
        reason: "session id conflict"
      )
    end

    add_log(
      "Runtime refused to start: session id #{session.session_id} is already in use and nothing has been " \
      "written under it — retrying under a new session id (attempt #{attempt}/#{MAX_SESSION_ID_CONFLICT_RECOVERIES})",
      level: "warning"
    )
    @logger.warn("Recovering from a held runtime session id", attempt: attempt, session_id: session.session_id)

    fresh_start!(working_dir, reason: "session id conflict", renew_session_id: true)
  rescue => e
    # Bookkeeping must never be the thing that fails the session: without this, a
    # metadata write that exhausts its retries escapes handle_exit entirely.
    error_msg = "Session id conflict recovery failed: #{e.message}"
    add_log(error_msg, level: "error")
    @logger.error("Session id conflict recovery failed", error: e.message)
    @mutex.synchronize { @state = :idle }
    ExitDecision.new(action: :failed, error_message: error_msg)
  end

  # Restart this turn from scratch: abandon whatever runtime conversation the
  # session was pointed at and spawn a NEW one carrying the best durable prompt.
  #
  # Shared by every recovery that concludes there is nothing to resume into — a
  # resume the runtime could not find, a session id the runtime would not accept,
  # and a turn that ended without a single line of output.
  #
  # Note: Called while in :handling_exit state. Must transition to :running
  # on success or :idle on failure before returning.
  #
  # @param working_dir [String] Working directory for spawning fresh process
  # @param reason [String] Human-readable cause, for logs and error messages
  # @param renew_session_id [Boolean] Mint a new runtime session id first
  # @return [ExitDecision] Decision on what to do next
  def fresh_start!(working_dir, reason:, renew_session_id: false)
    # Re-confirm before spawning, as every other respawn branch does: the status
    # check at the top of #handle_exit is milliseconds stale, and a user pause
    # landing in that window must not be answered with a restarted turn.
    unless wait_and_confirm_still_running
      add_log("Session status changed during #{reason} handling, aborting restart", level: "info")
      @mutex.synchronize { @state = :idle }
      return ExitDecision.new(action: :aborted)
    end

    session.reload

    prompt = recovery_prompt
    unless prompt.present?
      error_msg = "Cannot restart the turn after #{reason}: no prompt available for fresh start recovery"
      add_log(error_msg, level: "error")
      @mutex.synchronize { @state = :idle }
      return ExitDecision.new(action: :failed, error_message: error_msg)
    end

    recovery_base_line_count = session.transcript_line_count

    # Reset runtime_started so future spawns use --session-id instead of --resume.
    # Mark the transcript as a deliberate recovery segment: runtimes that mint a
    # new local conversation (Codex) may write a fresh transcript after this
    # spawn, and the poller must append that segment instead of replacing the
    # stored history.
    with_db_retry do
      session.merge_metadata!(
        "runtime_started" => false,
        "transcript_recovery_expected" => true,
        "transcript_recovery_base_line_count" => recovery_base_line_count
      )
    end

    renew_runtime_session_id! if renew_session_id

    add_log("Recovering from #{reason}: starting fresh CLI session with recovered prompt", level: "info")
    @logger.info("Fresh start recovery: spawning fresh CLI session", reason: reason)

    # One session, one live agent process — the same invariant #spawn enforces,
    # applied to the recovery path. Without it, a replacement spawned by an earlier
    # recovery that its job stopped monitoring stays alive on the clone and keeps
    # the runtime session id reserved, which is what turned a recoverable failure
    # into "Session ID … is already in use" in prod session 4668.
    AgentProcessLiveness.ensure_no_live_process!(
      session,
      process_manager: @process_manager,
      log_buffer: @log_buffer
    )

    # Reconstruct mcp_config_path if the session uses MCP servers (including
    # auto-injected self-session servers) — without this, the recovered session
    # would silently lose MCP server access.
    mcp_config_path = if session.all_mcp_servers.present?
      File.join(working_dir, ".mcp.json")
    end

    spawn_result = @cli_adapter.execute(
      prompt: prompt,
      session_id: session.session_id,
      working_dir: working_dir,
      mcp_config_path: mcp_config_path,
      append_system_prompt: @append_system_prompt,
      model: @model,
      auto_compact_window: session.auto_compact_window
    )

    new_pid = spawn_result[:pid]

    add_log("Fresh start recovery successful, spawned PID #{new_pid}", level: "info")

    release_stale_runtime_session_id!

    # Update session metadata with new process PID and re-set runtime_started
    with_db_retry do
      session.record_agent_process!(new_pid, "runtime_started" => true)
    end

    # Update our state to reflect the new process
    @mutex.synchronize do
      @current_pid = new_pid
      @stderr_log_path = spawn_result[:stderr_log_path]
      @state = :running
    end

    @logger.info("Fresh start recovery successful", new_pid: new_pid, reason: reason)

    ExitDecision.new(action: :continue)
  rescue => e
    error_msg = "Fresh start recovery after #{reason} failed: #{e.message}"
    add_log(error_msg, level: "error")
    @logger.error("Fresh start recovery failed", reason: reason, error: e.message)
    @mutex.synchronize { @state = :idle }
    ExitDecision.new(action: :failed, error_message: error_msg)
  end

  # The best durable prompt to replay when a turn has to start over.
  #
  # Prefer the in-flight follow-up over the original session prompt. A turn that
  # never reached the runtime's durable conversation has to replay the prompt that
  # spawned it:
  #
  # - active_follow_up_prompt: AgentSessionJob moves trigger/deploy/heartbeat
  #   recovery prompts here while delivering the turn, after clearing the
  #   "not picked up yet" pending marker. It holds the expanded prompt Zimmer
  #   attempted to deliver to the runtime, including goal/notes/provenance.
  # - sent_message: web follow-ups keep this until transcript polling confirms
  #   the user message landed.
  # - pending_follow_up_prompt: fallback for paths that have stamped a prompt
  #   but have not yet reached AgentSessionJob's delivery handoff.
  # - session.prompt: original prompt for a barely-started session with no
  #   follow-up in flight.
  #
  # Without the active/pending follow-up fallbacks, deploy auto-continuation can
  # lose its recovery prompt after Codex rejects `thread/resume` with "no rollout
  # found", parking the session in needs_input with unfinished side effects.
  def recovery_prompt
    session.metadata&.dig("active_follow_up_prompt").presence ||
      session.metadata&.dig("sent_message").presence ||
      session.metadata&.dig("pending_follow_up_prompt").presence ||
      session.prompt
  end

  # Whether a normal-looking exit should be answered by restarting the turn
  # because the runtime never wrote anything. See #handle_empty_turn.
  def empty_turn_recovery_needed?(working_dir)
    session.reload
    return false if empty_turn_recovery_count >= MAX_EMPTY_TURN_RECOVERIES
    return false if recovery_prompt.blank?

    !conversation_persisted?(working_dir)
  rescue => e
    # A backstop that cannot answer must not become the thing that breaks exit
    # handling; fall through to the pre-existing park.
    @logger.error("Failed to evaluate empty-turn recovery", error: e.message)
    false
  end

  # Whether either transcript store holds anything for this session. Asked of both
  # (RuntimeConversationPresence) rather than of Zimmer's polled copy alone: a
  # lagging or broken poller must not be enough to make Zimmer conclude the
  # runtime wrote nothing and abandon a conversation that really exists.
  def conversation_persisted?(working_dir)
    RuntimeConversationPresence.persisted?(
      session: session,
      working_directory: working_dir,
      file_system: @file_system
    )
  end

  def empty_turn_recovery_count
    session.metadata&.dig("empty_turn_recovery_count").to_i
  end

  # Whether the runtime refused this spawn because the session id was still held.
  # Runtimes whose strategy does not answer the question (Codex) never route here.
  def session_id_conflict?
    return false unless retry_strategy.respond_to?(:session_id_conflict?)

    retry_strategy.session_id_conflict?(stderr_log_path: @stderr_log_path)
  rescue => e
    @logger.error("Failed to ask the retry strategy about a session id conflict", error: e.message)
    false
  end

  # Mint a new runtime session id so a fresh start is not blocked by the old one.
  #
  # A no-op for runtimes that mint their own (Codex): the id Zimmer holds is a
  # record of what the runtime chose, not an instruction to it, and
  # #release_stale_runtime_session_id! is what clears that.
  def renew_runtime_session_id!
    return if TranscriptRuntime.normalizer_for(session).mints_own_session_id?

    new_id = SecureRandom.uuid
    add_log("Replacing held runtime session id #{session.session_id} with #{new_id}", level: "warning")
    with_db_retry { session.update_column(:session_id, new_id) }
  end

  # Drop the runtime session id that the just-failed resume was targeting, for
  # runtimes that mint their own.
  #
  # A fresh start is a new conversation as far as the CLI is concerned. Codex
  # ignores the `--session-id` Zimmer passes and mints a new rollout UUID, so the
  # id still stored on the session now names a rollout this process will never
  # write to — the very rollout the resume just failed to find.
  #
  # Leaving it in place deadlocks transcript polling: CodexTranscriptSource#
  # find_main_transcript prefers the rollout whose filename carries the stored
  # id, so the poller keeps reading the abandoned file, and the only code that
  # would learn the new UUID (TranscriptPollerService#capture_runtime_session_id!)
  # reads it from a file the locator will never hand it. Clearing the id makes the
  # locator fall back to matching on this session's clone path, which finds the
  # live rollout and re-attaches within one poll.
  #
  # A no-op for Claude Code, which honors the supplied `--session-id`, so its
  # stored id stays authoritative across a fresh start.
  def release_stale_runtime_session_id!
    return unless TranscriptRuntime.normalizer_for(session).mints_own_session_id?
    return if session.session_id.blank?

    add_log(
      "Releasing stale runtime session id #{session.session_id} so transcript polling re-attaches to the new transcript",
      level: "info"
    )
    with_db_retry { session.update_column(:session_id, nil) }
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

  # The stderr log to tail after a retry service respawned the process out of
  # band. Those services hand back only a pid, so the path has to be rebuilt —
  # from the session's working directory, named by the adapter actually driving
  # this session (an extension override included). The recovery paths that spawn
  # inline use the adapter's own answer (`spawn_result[:stderr_log_path]`) instead.
  def rebuilt_stderr_log_path
    @cli_adapter.class.stderr_log_path(session.working_directory)
  end

  # Surface the tail of the process's stderr to the session log on a genuine
  # failure so the user sees the actual error (e.g. a Codex "no rollout found"
  # message) instead of a blank turn. No-op when there is no stderr log or it is
  # empty. Failures here are non-fatal — they must never mask the failure itself.
  def surface_stderr_to_session_log
    tail = stderr_tail
    return if tail.blank?

    add_log("Process stderr:\n#{tail}", level: "error")
  rescue => e
    @logger.error("Failed to surface stderr to session log", error: e.message)
  end

  # The trailing STDERR_TAIL_LINES lines of the process's stderr log, or nil when
  # there is none. Shared by the session-log surfacing above and the unclassified
  # failure alert, which needs the same text as its "unmatched output".
  def stderr_tail
    return nil unless @stderr_log_path
    return nil unless @file_system.exists?(@stderr_log_path)

    content = @file_system.read(@stderr_log_path)
    return nil if content.blank?

    content.strip.split("\n").last(STDERR_TAIL_LINES).join("\n")
  rescue => e
    @logger.error("Failed to read stderr tail", error: e.message)
    nil
  end

  # Announce an exit that no classifier recognized, carrying the output the
  # patterns failed to match: the stderr tail plus, when the runtime can supply
  # one, the most recent transcript error entry it could not classify.
  #
  # Failures here are non-fatal — an alert that cannot be raised must never
  # change how the session itself is failed.
  def report_unclassified_exit(error_msg, working_dir)
    runtime = session&.agent_runtime.presence || "unknown runtime"

    # A runtime whose strategy classifies nothing (Codex, today) reaches this
    # branch on EVERY ordinary failure. Paging on its designed-for path would be
    # a standing hourly alert for expected behavior, so it logs and stops.
    unless runtime_classifies_exits?
      @logger.warn(
        "Unclassified process exit on a runtime with no exit classifiers — logging without alerting",
        runtime: runtime, exit: error_msg
      )
      return
    end

    UnclassifiedFailureReporter.report(
      kind: "process exit",
      # The runtime belongs in the summary because the summary IS the dedup key.
      # Without it a routine failure on one runtime would hold the key for an
      # hour and suppress a genuinely novel failure on another sharing its exit
      # code.
      summary: "#{runtime} session process died with #{error_msg} and no recovery classifier matched",
      source: "ProcessLifecycleManager#handle_exit",
      session: session,
      output: [ stderr_tail, unclassified_runtime_error_text(working_dir) ].compact.join("\n\n").presence,
      logger: @logger
    )
  rescue => e
    @logger.error("Failed to report unclassified process exit", error: e.message)
  end

  # Session metadata key holding the transcript line the backstop last fired on.
  # A dead turn is failed once; a resume that writes nothing new leaves the same
  # entry terminal, and re-failing on it would turn one bad turn into a loop of
  # failures and alerts.
  TERMINAL_API_ERROR_LINE_KEY = "terminal_api_error_line"

  # A turn that ended on an API error nobody is handling. Fails the session and,
  # when the wording is one no classifier knows, alerts.
  #
  # Failing is the honest verdict: the turn is over, the work in it did not
  # happen, and the human's prompt is sitting unanswered in the transcript. A
  # failed session says all three on the homepage and stays resumable, where
  # `needs_input` said the opposite of all three.
  def handle_terminal_api_error(terminal)
    add_log(
      "Turn ended on an API error and no recovery path claimed it, so it did not complete — failing " \
        "loudly rather than parking it as finished. The runtime said: #{terminal.text}",
      level: "error"
    )
    @log_buffer&.flush
    @logger.error("Turn ended on an unhandled API error",
      unmatched_output: terminal.text, recognized: terminal.recognized?)

    remember_terminal_api_error_line(terminal.line)

    # Only an unrecognized wording is news. A recognized error that got here has
    # already been through its own classifier, which declined — that is a dead
    # turn, but not an unknown failure mode, and paging on it would be noise.
    report_terminal_api_error(terminal.text) unless terminal.recognized?

    @mutex.synchronize { @state = :idle }
    ExitDecision.new(
      action: :failed,
      error_message: "Turn ended on an API error no recovery path claimed: #{terminal.text.truncate(300)}"
    )
  end

  def report_terminal_api_error(error_text)
    return unless runtime_classifies_exits?

    UnclassifiedFailureReporter.report(
      kind: "terminal API error",
      # Low-cardinality by construction: the summary IS the dedup key, so it
      # carries the runtime and not the error text, session id, or timestamp.
      summary: "#{session&.agent_runtime.presence || "unknown runtime"} turn ended on an API error no classifier matched",
      source: "ProcessLifecycleManager#handle_exit",
      session: session,
      output: error_text,
      logger: @logger
    )
  rescue => e
    @logger.error("Failed to report a terminal API error", error: e.message)
  end

  # The API error this turn died on, unless it is the same one a previous exit
  # already failed for. Runtimes whose strategy does not answer the question
  # (Codex) never route here.
  def unhandled_terminal_api_error(working_dir)
    return nil unless retry_strategy.respond_to?(:terminal_api_error)

    terminal = retry_strategy.terminal_api_error(working_dir: working_dir)
    return nil unless terminal
    return nil if terminal.line == session.metadata&.dig(TERMINAL_API_ERROR_LINE_KEY)

    terminal
  rescue => e
    # A backstop that cannot answer must not become the thing that breaks exit
    # handling; fall through to the pre-existing park.
    @logger.error("Failed to check for a terminal API error", error: e.message)
    nil
  end

  def remember_terminal_api_error_line(line)
    with_db_retry do
      session.update!(metadata: (session.metadata || {}).merge(TERMINAL_API_ERROR_LINE_KEY => line))
    end
  rescue => e
    # Worst case the same dead turn is failed twice; that must not stop it being
    # failed once.
    @logger.error("Failed to record the terminal API error line", error: e.message)
  end

  # Whether this runtime's strategy answers real questions about an exit, so that
  # "nothing matched" is genuinely informative. Strategies predating the question
  # are assumed to classify — the conservative answer, since it keeps alerting.
  def runtime_classifies_exits?
    return true unless retry_strategy.respond_to?(:classifies_exits?)

    retry_strategy.classifies_exits?
  rescue => e
    @logger.error("Failed to ask the retry strategy whether it classifies exits", error: e.message)
    true
  end

  # A classifier said a recovery path applied, then that path's service reported
  # it did not — the two disagree about the same exit. Every such branch is
  # commented "shouldn't happen" and each one fails the session, so the
  # disagreement is exactly the kind of unknown that must announce itself rather
  # than land as a bare "recovery failed" string in the session log.
  def report_recovery_contradiction(handler, result)
    UnclassifiedFailureReporter.report(
      kind: "recovery contradiction",
      summary: "#{handler} was selected by its classifier but the recovery service returned #{result}",
      source: "ProcessLifecycleManager##{handler}",
      session: session,
      output: stderr_tail,
      logger: @logger
    )
  rescue => e
    @logger.error("Failed to report recovery contradiction", error: e.message)
  end

  # The runtime's own unmatched error prose, if its retry strategy can produce
  # one. Strategies that cannot (Codex, whose transcript envelope parsing is not
  # characterized yet) return nil and the alert carries stderr alone.
  def unclassified_runtime_error_text(working_dir)
    return nil unless retry_strategy.respond_to?(:unclassified_error_text)

    retry_strategy.unclassified_error_text(working_dir: working_dir)
  rescue => e
    @logger.error("Failed to read unclassified runtime error text", error: e.message)
    nil
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
        @stderr_log_path = rebuilt_stderr_log_path
        @state = :running
      end
      ExitDecision.new(action: :continue)
    when :exhausted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :failed, error_message: "API error retry limit exhausted")
    when :quota_exceeded
      rotation_result = attempt_account_rotation(working_dir)
      return rotation_result if rotation_result

      # Nothing left to rotate into. Park the session with an explicit warning
      # and put to sleep, instead of dropping it into a bare needs_input
      # whose only visible artifact is the runtime's own error text.
      park_for_auth_outage(AuthOutageParkService::QUOTA_EXHAUSTED)

      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :needs_input, error_message: "Account quota limit reached and no other accounts available — session parked until quota resets")
    when :aborted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :aborted)
    when :not_applicable
      # Shouldn't happen since we checked retry_strategy.api_error_for_retry? first, but handle gracefully
      report_recovery_contradiction("handle_retryable_api_error", retry_result)
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
        @stderr_log_path = rebuilt_stderr_log_path
        @state = :running
      end
      ExitDecision.new(action: :continue)
    when :exhausted
      # Rotating and re-injecting did not clear the error within the attempt
      # budget. Which park reason that justifies depends on the pool, not on the
      # fact we ran out of tries: if the budget ran out while the pool was being
      # drained by quota, telling the user to re-authenticate is wrong — waiting
      # is what fixes it. AuthRecoveryCoordinator#park_reason_for_pool reads the
      # pool's current shape and answers that.
      reason = auth_park_reason_for_pool
      park_for_auth_outage(reason)

      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :needs_input, error_message: exhausted_auth_message(reason))
    when :pool_quota_exhausted
      # Every account is over quota with nothing to rotate into. Same verdict the
      # quota path reaches, reached on the FIRST auth failure instead of after
      # three re-spawns into the same wall — and with the reset-derived retry
      # reason, so the session log and the banner name the outage the pool is
      # actually in.
      park_for_auth_outage(AuthOutageParkService::QUOTA_EXHAUSTED)

      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :needs_input, error_message: "Account quota limit reached and no other accounts available — session parked until quota resets")
    when :unrecoverable
      # No valid account available to recover to — surface to the user (re-auth
      # needed) rather than failing silently or looping.
      park_for_auth_outage(AuthOutageParkService::AUTH_UNRECOVERABLE)

      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :needs_input, error_message: "Not logged in and no valid account available to recover — re-authenticate an account to restore service")
    when :aborted
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :aborted)
    when :not_applicable
      # Shouldn't happen since we checked retry_strategy.auth_recovery_needed? first, but handle gracefully
      report_recovery_contradiction("handle_auth_recovery", result)
      @mutex.synchronize { @state = :idle }
      ExitDecision.new(action: :failed, error_message: "Auth recovery failed")
    end
  end

  # Which outage the pool's current shape justifies once the auth-recovery budget
  # is spent. Falls back to AUTH_UNRECOVERABLE if the pool can't be read at all —
  # the conservative answer, since it asks a human to look.
  def auth_park_reason_for_pool
    AuthRecoveryCoordinator.new(@session).park_reason_for_pool
  rescue => e
    @logger.info("Could not derive auth park reason from the pool", error: e.message)
    AuthOutageParkService::AUTH_UNRECOVERABLE
  end

  def exhausted_auth_message(reason)
    if reason == AuthOutageParkService::QUOTA_EXHAUSTED
      "Auth recovery exhausted with every account over quota — session parked until quota resets"
    else
      "Auth recovery retry limit exhausted — session parked until the login pool recovers"
    end
  end

  # Park the session for an auth/quota outage: explain it in the session log,
  # notify the user, and put the session to sleep until the pool recovers. See
  # AuthOutageParkService.
  #
  # Parking sets pending_sleep on this still-running session, so the needs_input
  # the caller returns is immediately followed by a transition to waiting — which
  # is also what stops the heartbeat sweep from nudging the session straight back
  # into the same wall.
  def park_for_auth_outage(reason)
    return unless @session

    AuthOutageParkService.new(@session, log_buffer: @log_buffer, logger: @logger).park!(reason: reason)
  end

  # Attempt to rotate to a different account for the session's runtime after a
  # quota-exceeded exit. Returns an ExitDecision if rotation succeeded, nil if no
  # accounts available.
  def attempt_account_rotation(working_dir)
    provider = RuntimeAuthProvider.for(@session&.agent_runtime)
    result = provider.rotate_for_quota!(
      triggered_by: @session ? "session:#{@session.id}" : nil,
      # The identity this session's process was actually running as. A quota
      # stampede has N sessions arrive here about the SAME account; passing it
      # lets everyone after the first collapse onto that rotation instead of
      # burning one more account each (#242).
      expected_current_email: @session&.metadata&.dig(AuthRecoveryCoordinator::IDENTITY_KEY)
    )

    # Losing the lock race is not an exhausted pool. Another process is mid-rotation
    # and its credential write is already in progress, so resume against what it
    # lands rather than parking a session whose pool is fine.
    if result[:reason] == "rotation_in_flight"
      add_log("Account quota hit — another session's rotation is still running, resuming after it", level: "warning")
      @log_buffer&.flush
      return spawn_continuation(
        working_dir: working_dir,
        prompt: AutomatedPrompts::SYSTEM_RECOVERY,
        reason: "account rotation in flight"
      )
    end

    return nil unless result[:success]

    AuthRecoveryCoordinator.record_identity!(@session, result[:account])

    add_log(
      result[:collapsed] ? "Account quota hit — another session had already rotated to #{result[:account].email}" : "Account quota hit — rotated to #{result[:account].email}",
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
