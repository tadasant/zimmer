class AgentSessionJob < ApplicationJob
  include DatabaseRetry
  include McpServerBackfill

  require "path_sanitizer"

  queue_as :agents

  # ============================================================================
  # Job Enqueuing Helpers
  # ============================================================================
  #
  # These class methods provide a single source of truth for enqueuing AgentSessionJob
  # with the correct argument patterns. Use these instead of calling perform_later directly.
  #
  # Historical context:
  # 30% of production bugs were caused by incorrect argument passing due to Ruby's
  # flexible keyword/positional argument handling:
  #   perform_later(session_id, resume_monitoring: true)      # WRONG - Hash as positional arg
  #   perform_later(session_id, nil, resume_monitoring: true) # CORRECT - nil + keyword arg
  #
  # See test/contracts/job_contract_test.rb for contract tests that enforce correct usage.
  # ============================================================================

  # Enqueue a job to start a new session with its initial prompt
  #
  # @param session_id [Integer] The session ID to start
  # @param images [Array<Hash>, nil] Array of image data hashes with :path, :media_type keys
  # @param files [Array<Hash>, nil] Array of file data hashes with :path, :original_filename, :size keys
  # @return [AgentSessionJob] The enqueued job instance
  # @raise [ArgumentError] if session_id is nil
  #
  # @example Start a new session
  #   AgentSessionJob.enqueue_new_session(session.id)
  # @example Start a new session with images
  #   AgentSessionJob.enqueue_new_session(session.id, images: [{ path: "/tmp/.../img.png", media_type: "image/png" }])
  def self.enqueue_new_session(session_id, images: nil, files: nil, delay: nil)
    raise ArgumentError, "session_id cannot be nil" if session_id.nil?

    options = {}
    options[:images] = images if images.present?
    options[:files] = files if files.present?

    target = delay ? set(wait: delay) : self

    if options.any?
      target.perform_later(session_id, nil, **options)
    else
      target.perform_later(session_id)
    end
  end

  # Enqueue a job to send a follow-up prompt to an existing session
  #
  # @param session_id [Integer] The session ID to continue
  # @param prompt [String] The follow-up prompt to send (required, non-blank)
  # @param images [Array<Hash>, nil] Array of image data hashes with :path, :media_type keys
  # @return [AgentSessionJob] The enqueued job instance
  # @raise [ArgumentError] if session_id is nil, or if prompt is nil, blank, or not a String
  #
  # @example Send a follow-up prompt
  #   AgentSessionJob.enqueue_with_prompt(session.id, "Please continue")
  #
  # @example Send a prompt with images
  #   AgentSessionJob.enqueue_with_prompt(session.id, "What's in this image?", images: [
  #     { path: "/tmp/image.png", media_type: "image/png" }
  #   ])
  def self.enqueue_with_prompt(session_id, prompt, images: nil, files: nil, delay: nil)
    raise ArgumentError, "session_id cannot be nil" if session_id.nil?
    raise ArgumentError, "prompt must be a String" unless prompt.is_a?(String)
    raise ArgumentError, "prompt cannot be blank" if prompt.blank?

    options = {}
    options[:images] = images if images.present?
    options[:files] = files if files.present?

    target = delay ? set(wait: delay) : self

    if options.any?
      target.perform_later(session_id, prompt, **options)
    else
      target.perform_later(session_id, prompt)
    end
  end

  # Enqueue a job to resume monitoring an existing Claude CLI process
  #
  # Use this when reconnecting to a session whose process is still running,
  # such as after a server restart or job recovery.
  #
  # @param session_id [Integer] The session ID to resume monitoring
  # @param delay [ActiveSupport::Duration] Optional delay before the job runs (default: none)
  # @return [AgentSessionJob] The enqueued job instance
  # @raise [ArgumentError] if session_id is nil
  #
  # @example Resume monitoring immediately
  #   AgentSessionJob.enqueue_for_monitoring(session.id)
  #
  # @example Resume monitoring after 5 seconds
  #   AgentSessionJob.enqueue_for_monitoring(session.id, delay: 5.seconds)
  def self.enqueue_for_monitoring(session_id, delay: nil)
    raise ArgumentError, "session_id cannot be nil" if session_id.nil?

    if delay
      set(wait: delay).perform_later(session_id, nil, resume_monitoring: true)
    else
      perform_later(session_id, nil, resume_monitoring: true)
    end
  end

  # Enqueue a job to set up a clone-only session without starting Claude CLI
  #
  # This creates the git clone and MCP configuration but doesn't spawn a process.
  # The session remains in needs_input status, waiting for a follow-up prompt.
  #
  # @param session_id [Integer] The session ID to set up
  # @return [AgentSessionJob] The enqueued job instance
  # @raise [ArgumentError] if session_id is nil
  #
  # @example Set up a clone-only session
  #   AgentSessionJob.enqueue_for_clone_only(session.id)
  def self.enqueue_for_clone_only(session_id)
    raise ArgumentError, "session_id cannot be nil" if session_id.nil?

    perform_later(session_id, nil, resume_monitoring: false, clone_only: true)
  end

  # Maximum consecutive transcript poll failures before failing the session
  MAX_TRANSCRIPT_POLL_FAILURES = 10

  # Job-level retry budget for transient git clone failures during session
  # startup. GitCloneService already retries `git clone` in-process on transient
  # errors, but its window is only ~4–5 minutes; a sustained slow-transfer window
  # (e.g. curl 28 low-speed aborts, GitHub 5xx during an incident) can outlast it.
  # When that happens the clone raises GitCloneService::TransientGitError, and
  # rather than hard-fail the session — forcing a human to notice and manually
  # restart, as happened to daily-pipeline session #9439 — we re-enqueue the whole
  # job on a longer, backed-off horizon so the transient condition has time to
  # clear. The delays escalate and the budget is bounded so a genuinely broken
  # repo/network eventually fails loudly instead of retrying forever. Permanent
  # failures (auth, missing repo/branch) are NOT retried here — they surface as a
  # plain GitError and fail fast.
  MAX_CLONE_JOB_RETRIES = 5
  CLONE_JOB_RETRY_DELAYS_SECONDS = [ 30, 60, 120, 300, 600 ].freeze

  # Age threshold for treating an unlocked job as stale. If a job has no lock and
  # was created longer ago than this, it is considered abandoned (never picked up).
  STALE_UNLOCKED_JOB_AGE = 2.minutes

  # Minimum successful run duration (seconds) before resetting SIGTERM retry counter.
  # When a process runs successfully for this duration after a SIGTERM retry,
  # the retry counter is reset to 0, allowing fresh retries for future SIGTERMs.
  # This prevents premature session failures when multiple SIGTERM events are
  # separated by periods of successful operation.
  SIGTERM_RETRY_RESET_THRESHOLD = 60

  # Upper bound (characters) on the exception message persisted into
  # metadata["exception_message"] when a session fails. The actionable part of a
  # failure — e.g. an AirPrepareError embeds the full `air prepare` stderr/stdout,
  # often several thousand chars with the real error buried at the tail — must
  # survive intact for diagnosis. The cap exists only as a safety valve against
  # pathological multi-megabyte messages bloating the session's metadata JSON; it
  # is set generously so real failure output is preserved in full.
  EXCEPTION_MESSAGE_MAX_CHARS = 20_000

  # Only retry on specific transient errors, not all StandardErrors
  # This prevents duplicate job executions that could create multiple PRs
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ETIMEDOUT, wait: :polynomially_longer, attempts: 3

  # Don't retry if session is not found
  discard_on ActiveRecord::RecordNotFound

  # Discard if the session already has a running job
  discard_on ActiveJob::DeserializationError

  # Handle GoodJob::InterruptError for deploy recovery.
  #
  # GoodJob's InterruptErrors extension raises InterruptError in an around_perform
  # callback BEFORE perform() runs, when a job is retried after worker shutdown.
  # This means a rescue block inside perform() can never catch it.
  #
  # The ApplicationJob base class quietly discards interrupted jobs via
  # `discard_interrupt_quietly` (a rescue_from that logs at INFO). That's fine for most
  # jobs, but for AgentSessionJob we need to transition the session to needs_input with
  # paused_by: "recovery" so the deployment recovery system auto-continues it.
  #
  # This rescue_from takes precedence over ApplicationJob's handler because
  # rescue_from uses a stack (last registered wins).
  rescue_from GoodJob::InterruptError do |error|
    handle_interrupt_error(error)
  end

  # Allow injection of dependencies for testing
  attr_accessor :process_manager, :file_system, :cli_adapter, :broadcast_service

  def initialize(*args)
    super
    @process_manager ||= SystemProcessManager.new
    @file_system ||= RealFileSystemAdapter.new
    @broadcast_service ||= BroadcastService.new
    # Do NOT default @cli_adapter here: the runtime (claude_code vs codex) isn't
    # known until we have a session, and forcing ClaudeCliAdapter would make every
    # session — including Codex — spawn the Claude CLI. It's resolved per-session in
    # cli_adapter_for. Tests still inject a mock via the attr_writer (used as-is).
    if @cli_adapter
      @cli_adapter.process_manager = @process_manager
      @cli_adapter.file_system = @file_system
    end
  end

  # Resolve the CLI adapter for a session, preferring an injected adapter (tests)
  # and otherwise selecting it from the session's runtime bundle so Codex sessions
  # spawn the codex CLI and claude_code/nil sessions spawn the Claude CLI. Memoized
  # so a single job reuses one adapter instance, wired to our pm/fs.
  def cli_adapter_for(session)
    @cli_adapter ||= begin
      adapter = RuntimeRegistry.cli_adapter_class_for(session&.agent_runtime).new
      adapter.process_manager = @process_manager
      adapter.file_system = @file_system
      adapter
    end
  end

  # Create a ProcessLifecycleManager for this job
  # @param session [Session] The session to manage
  # @param log_buffer [LogBuffer] Buffer for logging
  # @return [ProcessLifecycleManager] The lifecycle manager instance
  def create_lifecycle_manager(session, log_buffer)
    ProcessLifecycleManager.new(
      session: session,
      cli_adapter: cli_adapter_for(session),
      process_manager: @process_manager,
      log_buffer: log_buffer,
      file_system: @file_system
    )
  end

  # ActiveJob serializes keyword arguments as a hash which becomes a positional argument
  # when deserialized by GoodJob. This happens when jobs are enqueued (via perform_later)
  # and later executed by workers. Direct perform() calls in tests still use keyword arguments.
  #
  # This method handles both cases:
  # - Direct calls: perform(session_id, prompt, resume_monitoring: true)
  # - Deserialized calls: perform(session_id, prompt, { "resume_monitoring" => true })
  def perform(session_id, follow_up_prompt = nil, options = nil, resume_monitoring: false, clone_only: false, images: nil, files: nil)
    # Handle options hash from ActiveJob deserialization
    # Use fetch to correctly handle explicit false values (|| would skip false and use default)
    if options.is_a?(Hash)
      resume_monitoring = options.fetch("resume_monitoring", options.fetch(:resume_monitoring, resume_monitoring))
      clone_only = options.fetch("clone_only", options.fetch(:clone_only, clone_only))
      images = options.fetch("images", options.fetch(:images, images))
      files = options.fetch("files", options.fetch(:files, files))
    end

    session = Session.find(session_id)
    clone_path = nil
    process_pid = nil
    stderr_log_path = nil
    log_streaming_thread = nil
    reusing_existing_clone = false
    log_buffer = LogBuffer.new(session)
    lifecycle_manager = create_lifecycle_manager(session, log_buffer)

    # Human-readable runtime label (e.g. "Claude Code", "Codex") for operator-facing
    # log lines. Hardcoding "Claude CLI" here previously sent operators debugging
    # Codex sessions down the wrong path — the spawn/monitoring logs claimed Claude
    # for sessions that actually run `codex exec`. Derive it from the session's
    # runtime so every log line names the binary that is actually running.
    runtime_label = RuntimeRegistry.label_for(session.agent_runtime)

    # Diagnostic logging for job entry (Fix #5 from issue #424)
    log_buffer.add(
      "[DIAGNOSTIC] Job started: session_id=#{session_id}, follow_up=#{follow_up_prompt.present?}, resume_monitoring=#{resume_monitoring}, clone_only=#{clone_only}",
      level: "debug"
    )

    begin
      # Prevent concurrent job executions for the same session
      # This prevents multiple agents from running simultaneously and creating duplicate PRs
      # Don't block if running_job_id points to THIS job (prevents self-blocking)
      if session.running_job_id.present? && session.running_job_id != job_id
        existing_job = GoodJob::Job.find_by(active_job_id: session.running_job_id)
        if existing_job && !existing_job.finished_at
          # Check if the existing job is actually alive — its lock holder must still exist.
          # When a GoodJob worker is killed (SIGKILL, OOM), jobs remain "locked" in the
          # database but the lock holder process no longer exists. Without this check,
          # follow-up jobs silently skip execution because they see a stale "running" job,
          # causing the session to get stuck with no feedback to the user.
          stale_lock = existing_job.locked_by_id.present? &&
                       !GoodJob::Process.exists?(id: existing_job.locked_by_id)
          unlocked_and_old = existing_job.locked_by_id.nil? &&
                             existing_job.created_at < STALE_UNLOCKED_JOB_AGE.ago

          if stale_lock || unlocked_and_old
            log_buffer.add(
              "Superseding stale job #{session.running_job_id} (stale_lock=#{stale_lock}, unlocked_old=#{unlocked_and_old})",
              level: "warning"
            )
          else
            log_buffer.add(
              "Skipping job - session already has a running job (ID: #{session.running_job_id})",
              level: "warning"
            )
            log_buffer.flush
            return
          end
        end
      end

      # Reclassify a follow-up/recovery prompt for a session that never
      # established a Claude session_id as a FRESH START.
      #
      # A "follow-up" or recovery prompt assumes there is a prior Claude
      # conversation to resume. When a session dies during its very first spawn —
      # before a session_id (and clone/working_directory) is ever generated — and
      # is later respawned/recovered with a prompt, there is nothing to resume.
      # Routing it through the follow-up branch raises "Cannot send follow-up
      # prompt: session_id is missing" and the session fails again in a loop.
      #
      # Instead, drop the follow-up classification so the new-session setup path
      # runs (create the clone, generate a session_id, spawn fresh). The session's
      # own prompt drives the fresh run; if it has none, the follow-up text becomes
      # the prompt so the agent still has a task to act on.
      if follow_up_prompt.present? && !resume_monitoring && !clone_only && session.session_id.blank?
        log_buffer.add(
          "Follow-up/recovery prompt received for session with no session_id " \
          "(never started) — treating as a fresh start instead of a resume",
          level: "warning"
        )
        session.update!(prompt: follow_up_prompt) if session.prompt.blank?
        follow_up_prompt = nil
      end

      # Store the job ID for tracking and timestamp for MCP log filtering
      # Note: Status transition to 'running' happens later, AFTER process is spawned
      # and process_pid is stored in metadata. This prevents a race condition where
      # the session is 'running' but has no process_pid yet (which would cause
      # "Cannot pause session: no process found" errors if user clicks Pause early).
      #
      # job_started_at is used to filter out stale MCP log entries from previous runs
      # when restarting a session. See GitHub issue #716.
      session.update!(
        job_id: job_id,
        running_job_id: job_id,
        metadata: (session.metadata || {}).merge("job_started_at" => Time.current.iso8601)
      )

      # Create initial log entry
      if clone_only
        log_buffer.add(
          "Setting up clone-only session without initial prompt",
          level: "info"
        )
      elsif resume_monitoring
        log_buffer.add(
          "Resuming monitoring of existing #{runtime_label} CLI process",
          level: "info"
        )
      elsif follow_up_prompt.present?
        truncated_prompt = follow_up_prompt.length > 200 ? "#{follow_up_prompt[0..197]}..." : follow_up_prompt
        log_buffer.add(
          "Follow-up job started with prompt: #{truncated_prompt}",
          level: "info"
        )

        # Verify session is in the correct state for follow-up.
        # A follow-up job should proceed if the session is running OR needs_input.
        # The session may have reverted to needs_input between the controller's resume!
        # call and job execution (e.g., recovery/cleanup detected no active process).
        # In that case, re-transition to running since we're about to spawn a new process.
        unless session.running?
          if session.may_resume?
            log_buffer.add(
              "Follow-up job re-resuming session (status was #{session.status})",
              level: "info"
            )
            session.resume!
          else
            log_buffer.add(
              "Follow-up job skipped - session cannot be resumed (status: #{session.status})",
              level: "warning"
            )
            log_buffer.flush
            return
          end
        end

        # Clear the pending_follow_up_prompt and sent_at from metadata now that we're processing it.
        # This prevents the SIGTERM retry service from using a stale prompt and signals to the
        # pause action that the message has been picked up for processing.
        if session.metadata&.dig("pending_follow_up_prompt").present?
          session.update!(
            metadata: session.metadata.except("pending_follow_up_prompt", "pending_follow_up_sent_at")
          )
        end
      else
        log_buffer.add(
          "Job started for session #{session_id}",
          level: "info"
        )
      end

      # Skip setup and spawning if we're just resuming monitoring
      # When resume_monitoring is true, we don't spawn a new process or send new prompts
      # We only reconnect to the existing Claude CLI process to continue monitoring
      if resume_monitoring
        # Retrieve existing process info from metadata
        process_pid = session.metadata&.dig("process_pid")
        clone_path = session.metadata&.dig("clone_path")
        stderr_log_path = File.join(clone_path, "claude_stderr.log") if clone_path

        unless process_pid && clone_path
          raise "Cannot resume monitoring: missing process_pid or clone_path in session metadata"
        end

        # Validate session state before attempting to resume
        validation_result = validate_session_for_resume(session, clone_path)
        unless validation_result[:valid]
          log_buffer.add(
            "Session validation failed for resume: #{validation_result[:reason]}",
            level: "error"
          )
          log_buffer.flush
          session.update!(running_job_id: nil, metadata: (session.metadata || {}).merge("failure_reason" => validation_result[:reason]))
          session.fail! if session.may_fail?
          return
        end

        # Log any warnings (e.g., transcript cache issues) but continue with resume
        if validation_result[:warning]
          log_buffer.add(validation_result[:warning], level: "warning")
        end

        # Use lifecycle_manager to resume monitoring
        resume_result = lifecycle_manager.resume_monitoring(
          pid: process_pid,
          stderr_log_path: stderr_log_path
        )

        if resume_result.success?
          # CONFIRM: Update running_job_id to this job's ID
          session.update!(running_job_id: job_id)

          log_buffer.add(
            "Reconnected to existing #{runtime_label} CLI process #{process_pid} (recovery confirmed)",
            level: "info"
          )
        else
          log_buffer.add(
            "Process #{process_pid} is no longer running: #{resume_result.error}",
            level: "warning"
          )
          log_buffer.flush
          # Try to hand off to a queued message BEFORE pausing — if a message is
          # ready, we can continue without going through the recovery flow at all.
          # This avoids a transient running → needs_input → running flap that fires
          # ao_event watchers spuriously (see comment at the :needs_input
          # exit-decision branch).
          if process_next_enqueued_message_if_available(session, log_buffer)
            log_buffer.add(
              "Enqueued message being processed after recovery, exiting current job (handoff path — no pause flap)",
              level: "info"
            )
            log_buffer.flush
            return
          end
          # Mark as recovery-initiated pause so CleanupOrphanedSessionsJob and
          # DeploymentRecoveryJob can auto-continue this session. Without this marker,
          # the session gets stuck at needs_input because no recovery path picks it up.
          session.update!(
            running_job_id: nil,
            metadata: (session.metadata || {}).merge("paused_by" => "recovery")
          )
          session.pause! if session.may_pause?
          # Broadcast status immediately for snappy UI updates (don't wait for after_update_commit)
          @broadcast_service.session_status(session)
          return
        end
      end

      # For resume_monitoring, update status to running here since we already have process_pid
      # For new sessions and follow-ups, status transition happens after process spawn (below)
      if resume_monitoring && !clone_only
        session.start! if session.may_start?
      end

      # Validate session has required data (skip for resume_monitoring)
      unless resume_monitoring
        unless session.git_root.present?
          raise "Session git_root is required"
        end
      end

      # Setup environment for new sessions or retrieve for follow-ups
      if resume_monitoring
        # Already retrieved above, skip to monitoring
      elsif follow_up_prompt.present?
        # For follow-up prompts, verify we have the necessary data
        unless session.session_id.present?
          raise "Cannot send follow-up prompt: session_id is missing"
        end

        clone_path = session.metadata&.dig("clone_path")
        working_directory = session.metadata&.dig("working_directory") || clone_path

        # If clone directory is missing (e.g., session was trashed and clone deleted,
        # then restored by a reuse_session trigger), recreate it before proceeding.
        unless clone_path && @file_system.exists?(clone_path)
          unless session.git_root.present?
            raise "Cannot send follow-up prompt: clone path not found and no git_root to recreate"
          end

          log_buffer.add(
            "Clone directory missing, recreating from #{session.git_root} (branch: #{session.branch || "main"})",
            level: "info"
          )

          begin
            clone_result = GitCloneService.create_clone(
              session.git_root,
              branch: session.branch || "main",
              subdirectory: session.subdirectory
            )
          rescue GitCloneService::GitError => e
            if GitCloneService.transient_clone_error?(e) &&
               schedule_transient_clone_retry(session, e, log_buffer, kind: "follow-up") {
                 |delay| self.class.enqueue_with_prompt(session_id, follow_up_prompt, images: images, files: files, delay: delay)
               }
              return
            end

            log_buffer.add("Git clone failed during follow-up: #{e.message}", level: "error")
            log_buffer.flush
            session.update!(
              running_job_id: nil,
              metadata: (session.metadata || {}).merge("failure_reason" => "git_clone_failed")
            )
            session.fail! if session.may_fail?
            return
          end

          clone_path = clone_result[:clone_path]
          working_directory = clone_result[:working_directory]

          session.update!(
            metadata: (session.metadata || {}).merge(
              "clone_path" => clone_path,
              "working_directory" => working_directory,
              "full_clone_path" => working_directory,
              "clone_recreated" => true
            )
          )

          # Restore transcript so Claude Code can resume the conversation
          if session.transcript.present? && session.session_id.present?
            write_transcript_to_clone(session, working_directory, log_buffer)
          end

          log_buffer.add("Clone recreated at #{clone_path}", level: "info")
        end

        # Self-heal a regressed on-disk transcript before resuming. `--resume` reads
        # the clone's local <session_id>.jsonl, NOT session.transcript. If a prior
        # clone recreation (or an interrupted write) left that file shorter than the
        # canonical stored transcript — which TranscriptPollerService preserves in the
        # DB and flags via transcript_regression_detected, but never repairs on disk —
        # the runtime resumes a truncated conversation and no-ops straight back to
        # needs_input, silently dropping the user's prompt. Restore the full stored
        # transcript so the resume sees complete history. If the on-disk copy is
        # regressed and we cannot repair it, fail loud instead of resuming into a
        # silent no-op — a visible failed state is far better than a dropped prompt.
        unless restore_regressed_transcript_if_needed(session, working_directory, log_buffer)
          log_buffer.add(
            "Refusing to resume session #{session.session_id}: on-disk transcript is regressed and could not be repaired; resuming would silently drop the user's prompt",
            level: "error"
          )
          log_buffer.flush
          session.update!(
            running_job_id: nil,
            metadata: (session.metadata || {}).merge("failure_reason" => "transcript_regression_unrecovered")
          )
          session.fail! if session.may_fail?
          return
        end

        log_buffer.add(
          "Resuming session #{session.session_id} at working directory: #{working_directory}",
          level: "info"
        )

        # Re-run AIR prepare for follow-up prompts to sync skills, hooks, and MCP config.
        # Handles skills/hooks added/removed mid-session and new MCP servers.
        # Heal a mcp_servers column that landed empty at create time before deciding
        # between prepare! and the baseline fallback. Without this, a mid-run clone
        # recreation (this branch) regenerates .mcp.json from an empty server list and
        # ends up with only the auto-injected self-session server — silently stripping
        # every configured MCP server from the in-flight task. See McpServerBackfill.
        backfill_default_mcp_servers_if_empty(session)

        air_service = AirPrepareService.new(
          session: session,
          working_directory: working_directory,
          file_system: @file_system
        )
        if session.mcp_servers.present? || session.catalog_skills.present? || session.catalog_hooks.present? || session.catalog_plugins.present?
          air_service.prepare!
          log_buffer.add(
            "AIR prepare synced for follow-up prompt",
            level: "info"
          )
        else
          air_service.ensure_baseline_mcp_config!
        end
        store_injected_mcp_servers(session, air_service.injected_mcp_servers)

        # Check for OAuth requirements and inject credentials for follow-up prompts.
        # Necessary when MCP servers are added mid-session.
        return if gate_and_inject_oauth!(
          session,
          working_directory,
          log_buffer,
          blocked_message: "Follow-up blocked: OAuth authorization required for MCP servers"
        )
      else
        # Check if we already have a clone from a previous attempt (e.g., job retry)
        existing_clone = session.metadata&.dig("clone_path")
        existing_working_dir = session.metadata&.dig("working_directory")

        if existing_clone && @file_system.exists?(existing_clone)
          # RESUME: Reuse existing clone on retry
          clone_path = existing_clone
          working_directory = existing_working_dir || existing_clone
          reusing_existing_clone = true

          log_buffer.add(
            "Resuming with existing clone from previous attempt: #{clone_path}",
            level: "info"
          )

          if session.subdirectory.present?
            log_buffer.add(
              "Working directory: #{working_directory}",
              level: "info"
            )
          end

          # Re-inject OAuth credentials before spawning into the reused clone.
          # The reused-clone path is taken after a job retry AND after the user
          # completes an OAuth flow for an oauth_required-failed session (which
          # re-queues via enqueue_new_session). The clone already has a valid
          # .mcp.json from the first attempt, but the freshly-authorized DB
          # credential has NOT been written to the shared on-disk credential
          # store. Without this re-injection the CLI reads whatever stale token
          # a prior session left behind and fails with invalid_grant/401 —
          # exactly the loop where repeated re-authorization never resolves.
          return if gate_and_inject_oauth!(
            session,
            working_directory,
            log_buffer,
            blocked_message: "Session blocked: OAuth authorization required for MCP servers"
          )
        else
          # FRESH START: Create new clone only if starting fresh
          log_buffer.add(
            "[DIAGNOSTIC] Entering git clone block for session #{session_id}",
            level: "debug"
          )
          log_buffer.add(
            "Setting up clone and MCP configuration",
            level: "info"
          )

          begin
            log_buffer.add(
              "[DIAGNOSTIC] Calling GitCloneService.create_clone with git_root=#{session.git_root}, branch=#{session.branch}",
              level: "debug"
            )
            clone_result = GitCloneService.create_clone(
              session.git_root,
              branch: session.branch,
              subdirectory: session.subdirectory
            )
            clone_path = clone_result[:clone_path]
            working_directory = clone_result[:working_directory]
            log_buffer.add(
              "[DIAGNOSTIC] GitCloneService.create_clone returned successfully",
              level: "debug"
            )
          rescue GitCloneService::GitError => e
            # A transient failure whose in-process retries were exhausted surfaces
            # as TransientGitError. Rather than hard-fail the session (forcing a
            # human to notice and manually restart), re-enqueue the whole job on a
            # backed-off horizon so the transient condition can clear. Permanent
            # failures (auth, missing repo/branch) fall through and fail fast.
            if GitCloneService.transient_clone_error?(e) &&
               schedule_transient_clone_retry(session, e, log_buffer, kind: "startup") {
                 |delay| self.class.enqueue_new_session(session_id, images: images, files: files, delay: delay)
               }
              return
            end

            log_buffer.add(
              "Git clone failed: #{e.message}",
              level: "error"
            )
            log_buffer.add(
              "[DIAGNOSTIC] Git clone error handled, session transitioning to failed",
              level: "debug"
            )
            log_buffer.flush
            session.update!(
              running_job_id: nil,
              metadata: (session.metadata || {}).merge("failure_reason" => "git_clone_failed")
            )
            session.fail! if session.may_fail?
            return  # Handle completely here, don't re-raise to avoid duplicate state transitions
          end

          # Validate clone directory exists before proceeding (Fix #2 from issue #424)
          unless @file_system.exists?(clone_path) && @file_system.directory?(clone_path)
            error_msg = "Clone directory does not exist after GitCloneService.create_clone: #{clone_path}"
            log_buffer.add(error_msg, level: "error")
            log_buffer.add(
              "[DIAGNOSTIC] Clone validation failed, session transitioning to failed",
              level: "debug"
            )
            log_buffer.flush
            session.update!(
              running_job_id: nil,
              metadata: (session.metadata || {}).merge("failure_reason" => "clone_validation_failed")
            )
            session.fail! if session.may_fail?
            return  # Handle completely here, don't raise to avoid duplicate state transitions
          end

          log_buffer.add(
            "[DIAGNOSTIC] Clone directory validated successfully",
            level: "debug"
          )
          log_buffer.add(
            "Clone created at: #{clone_path}",
            level: "info"
          )

          if session.subdirectory.present?
            log_buffer.add(
              "Working directory set to subdirectory: #{working_directory}",
              level: "info"
            )
          end

          # Inject secrets from Rails credentials into .env file
          inject_secrets_to_env_file(working_directory, log_buffer)

          # Enqueue background bundle install if Gemfile exists
          # This runs asynchronously so Claude Code can start immediately
          # In most cases, Claude starts by reading files (doesn't need gems)
          if @file_system.exists?(File.join(working_directory, "Gemfile"))
            BundleInstallJob.perform_later(session.id, working_directory)
            log_buffer.add(
              "Bundle install started in background (Rails commands may not work for ~30s)",
              level: "info"
            )
          end

          # Generate and store session_id for new sessions
          session_id_uuid = SecureRandom.uuid
          session.update!(session_id: session_id_uuid)
          log_buffer.add(
            "Generated session_id: #{session_id_uuid}",
            level: "info"
          )

          # Store clone paths in session metadata
          # clone_path: base clone directory (e.g., ~/.agent-orchestrator/clones/agents-main-123-abc)
          # working_directory: actual working directory (may be subdirectory)
          # full_clone_path: full path including subdirectory if present (for copy button)
          # Clear any transient-clone-retry counter now that the clone succeeded.
          session.update!(
            metadata: (session.metadata || {}).except("clone_retry_count").merge(
              "clone_path" => clone_path,
              "working_directory" => working_directory,
              "full_clone_path" => working_directory
            )
          )

          # Use AIR CLI to generate MCP configuration and inject catalog skills.
          # AIR resolves air.json, writes .mcp.json, and copies skills + references
          # into .claude/skills/. Post-processing resolves ${VAR} interpolations
          # and applies AO-specific tweaks (npx --prefix, filesystem dirs).
          # Heal a mcp_servers column that landed empty at create time before deciding
          # between prepare! and the baseline fallback, so a root whose servers come
          # from default_in_roots doesn't regenerate .mcp.json with only the
          # auto-injected self-session server. See McpServerBackfill.
          backfill_default_mcp_servers_if_empty(session)

          air_service = AirPrepareService.new(
            session: session,
            working_directory: working_directory,
            file_system: @file_system
          )
          if session.mcp_servers.present? || session.catalog_skills.present? || session.catalog_hooks.present? || session.catalog_plugins.present?
            begin
              air_service.prepare!
            rescue AirPrepareService::RootResolutionError => e
              # The session's agent root can't be resolved from the AIR catalog
              # even after a cache refresh (AirPrepareService already busted the
              # github cache once and retried). This is a configuration problem
              # with the session, not broken-system behavior — fail the session
              # gracefully (WARN, no re-raise) rather than letting the error
              # bubble to ActiveJob as a terminal failure that pages #eng-alerts.
              # Mirrors the oauth_required graceful-fail path.
              log_buffer.add(
                "Session failed: agent root could not be resolved from the AIR catalog (#{e.message})",
                level: "warning"
              )
              log_buffer.flush
              session.update!(
                running_job_id: nil,
                metadata: (session.metadata || {}).merge(
                  "failure_reason" => "air_root_unresolvable"
                )
              )
              session.fail! if session.may_fail?
              return
            end
            log_buffer.add(
              "AIR prepare completed: MCP config and catalog skills generated",
              level: "info"
            )
          else
            air_service.ensure_baseline_mcp_config!
          end
          store_injected_mcp_servers(session, air_service.injected_mcp_servers)

          # Check for OAuth requirements and inject credentials after .mcp.json is written
          return if gate_and_inject_oauth!(
            session,
            working_directory,
            log_buffer,
            blocked_message: "Session blocked: OAuth authorization required for MCP servers"
          )

          # Discover Claude skills and commands from .claude directories
          discovered_skills = ClaudeSkillsDiscoveryService.discover(working_directory, clone_path: clone_path)
          if discovered_skills.any?
            log_buffer.add(
              "Discovered #{discovered_skills.size} Claude skills/commands",
              level: "info"
            )

            # Cache skills by agent root so the follow-up form typeahead can use them
            ClaudeSkillsCacheService.cache_for_agent_root(session.git_root, session.subdirectory, discovered_skills)
          end

          log_buffer.flush  # Flush setup logs
        end
      end

      # For clone-only sessions, we skip spawning the Claude CLI process
      if clone_only
        log_buffer.add(
          "Clone-only session created. Ready for follow-up prompts.",
          level: "info"
        )
        log_buffer.flush

        # Clear the running job ID since we're done
        session.update!(running_job_id: nil)

        log_buffer.add(
          "Session is ready to receive prompts. Use the follow-up prompt feature to send commands.",
          level: "info"
        )
        log_buffer.flush
        return
      end

      # Spawn Claude CLI process (skip if resuming monitoring)
      unless resume_monitoring
        log_buffer.add(
          "[DIAGNOSTIC] Entering #{runtime_label} CLI spawn block for session #{session_id}",
          level: "debug"
        )
        log_buffer.add(
          "Spawning #{runtime_label} CLI process",
          level: "info"
        )

        # Prepare working directory
        @file_system.mkdir_p(working_directory)

        # Determine prompt and spawn type
        # Set mcp_config_path for all cases where MCP servers are configured
        # (including auto-injected self-session servers). This ensures MCP_TIMEOUT
        # environment variable is set for resume/follow-up prompts. Without this,
        # resume attempts use the default 30s timeout which can cause failures when
        # MCP server packages need to be downloaded.
        mcp_config_path = session.all_mcp_servers.present? ? File.join(working_directory, ".mcp.json") : nil

        # Only use --resume if Claude CLI has actually been started before for this session.
        # Clone-only sessions have a session_id but Claude CLI has never been run,
        # so we need to use --session-id for their first prompt.
        #
        # CRITICAL: Reload session from database to get the latest metadata state.
        # This prevents race conditions where concurrent metadata updates (e.g., from
        # SessionTitleJob, transcript polling, or controller updates) could have
        # modified metadata using stale in-memory values, potentially losing the
        # runtime_started flag. Without this reload, follow-up prompts could
        # incorrectly use --session-id instead of --resume, causing "Session ID
        # already in use" errors from the Claude CLI.
        session.reload
        runtime_previously_started = session.metadata&.dig("runtime_started") == true
        is_resume = runtime_previously_started && (follow_up_prompt.present? || reusing_existing_clone)

        # Log the resume decision for debugging (helps diagnose "Session ID already in use" errors)
        log_buffer.add(
          "[DIAGNOSTIC] Spawn decision: runtime_started=#{runtime_previously_started}, follow_up=#{follow_up_prompt.present?}, reusing_clone=#{reusing_existing_clone}, is_resume=#{is_resume}",
          level: "debug"
        )

        if follow_up_prompt.present?
          prompt_with_goal = build_prompt_with_goal(follow_up_prompt, session)
        elsif is_resume
          # Genuine resume: the runtime CLI actually started before
          # (runtime_started=true) and we are reusing its clone. The CLI restores
          # the prior conversation from its own session state, so no positional
          # prompt is supplied.
          #
          # This MUST be keyed on is_resume, NOT on reusing_existing_clone alone.
          # A post-OAuth retry reuses the existing clone (reusing_existing_clone=true)
          # but the runtime CLI may never have started (runtime_started=false) — the
          # first attempt failed at the OAuth gate before spawning. Keying the
          # no-prompt resume shape on reusing_existing_clone would build a promptless
          # INITIAL spawn (is_resume=false), passing a nil positional argument to the
          # runtime and crashing with "command contains a nil argument" (prod session
          # 8698). is_resume is true only when runtime_started=true, so this branch is
          # reached only for a genuine resume.
          log_buffer.add(
            "Resuming existing #{runtime_label} CLI session on retry",
            level: "info"
          )
          prompt_with_goal = nil # Resume without prompt
        else
          # Fresh initial spawn. This includes the post-OAuth-retry case where we
          # reuse the existing clone (reusing_existing_clone=true) but the runtime CLI
          # never actually started (runtime_started=false). An initial spawn REQUIRES
          # the positional prompt, so supply the session's initial prompt.
          prompt_with_goal = build_prompt_with_goal(session.prompt, session)
        end

        # Append a structured note about attached files so the agent knows
        # they exist, where they are on disk, and how to read large ones.
        # The user's actual message text is preserved verbatim above.
        if files.present?
          if prompt_with_goal.present?
            prompt_with_goal = append_file_attachment_note(prompt_with_goal, files)
          else
            log_buffer.add(
              "Skipping #{files.size} attached file(s): no prompt text to attach them to (resuming existing session)",
              level: "warning"
            )
          end
        end

        # Guard: a non-resume (initial) spawn MUST carry a prompt. The runtime's
        # initial-spawn command appends the prompt as the positional argument after
        # "--"; a nil/blank prompt becomes a nil argv element that fails deep in the
        # adapter with a cryptic "command contains a nil argument" error (prod session
        # 8698). Fail loudly here, naming the real cause, so a never-started session can
        # never be silently spawned promptless.
        if !is_resume && prompt_with_goal.blank?
          log_buffer.add(
            "Refusing to spawn #{runtime_label} CLI without a prompt: this is an initial " \
            "(non-resume) spawn but the prompt is blank (session_id=#{session_id}, " \
            "follow_up=#{follow_up_prompt.present?}, reusing_clone=#{reusing_existing_clone}, " \
            "runtime_started=#{runtime_previously_started}). The session's initial prompt is missing.",
            level: "error"
          )
          log_buffer.flush
          session.update!(
            running_job_id: nil,
            metadata: (session.metadata || {}).merge("failure_reason" => "spawn_failed")
          )
          session.fail! if session.may_fail?
          return
        end

        # Build the orchestrator system prompt to provide context to Claude
        orchestrator_system_prompt = OrchestratorSystemPromptBuilder.build(
          session: session,
          clone_path: clone_path
        )

        # Ensure the runtime's login credentials are active on disk before spawning
        RuntimeAuthProvider.for(session.agent_runtime).inject_for_session!(session, working_directory)

        # Use ProcessLifecycleManager to spawn the process
        # Images are passed for follow-up prompts with attachments
        spawn_result = lifecycle_manager.spawn(
          prompt: prompt_with_goal,
          working_dir: working_directory,
          mcp_config_path: mcp_config_path,
          images: images,
          append_system_prompt: orchestrator_system_prompt,
          model: session.config&.dig("model"),
          resume: is_resume
        )

        unless spawn_result.success?
          log_buffer.add(
            "Failed to spawn #{runtime_label} CLI process: #{spawn_result.error}",
            level: "error"
          )
          log_buffer.flush
          session.update!(
            running_job_id: nil,
            metadata: (session.metadata || {}).merge("failure_reason" => "spawn_failed")
          )
          session.fail! if session.may_fail?
          return
        end

        process_pid = spawn_result.pid
        stderr_log_path = spawn_result.stderr_log_path

        # Log a concise, runtime-correct summary of the spawned command (for
        # debugging). The adapter owns this string so it names the real binary and
        # flags for whichever runtime is running — a single source of truth instead
        # of a hardcoded "claude ..." description that lied for Codex sessions.
        command_description = cli_adapter_for(session).command_summary(
          session_id: session.session_id,
          prompt: prompt_with_goal,
          mcp_config_path: mcp_config_path,
          resume: is_resume
        )
        log_buffer.add(
          "Command: #{command_description}",
          level: "info"
        )

        log_buffer.add(
          "#{runtime_label} CLI spawned with PID: #{process_pid}",
          level: "info"
        )
        log_buffer.add(
          "Stderr logs: #{stderr_log_path}",
          level: "info"
        )

        # Store PID in session metadata and transition to running
        # IMPORTANT: Status transition to 'running' MUST happen AFTER process_pid is stored
        # This prevents a race condition where user clicks Pause but process_pid isn't yet available
        # Also mark that the runtime CLI has been started for this session (used to determine
        # whether to use --resume vs --session-id on subsequent runs)
        #
        # NOTE: This uses a read-modify-write pattern which is not atomic. Concurrent metadata
        # updates elsewhere could be lost. However, since we're SETTING runtime_started=true
        # here, this is acceptable - the flag will be present even if we lose other updates.
        # For a complete solution to metadata race conditions, consider using PostgreSQL's
        # jsonb_set() for atomic JSON updates or moving critical flags to dedicated columns.
        session.reload # Ensure we have latest metadata before merging
        # Drop any stale interrupt_terminate_pid from a prior turn as we record
        # the new pid: it targeted a different (now-dead) process, and clearing
        # it here closes the theoretical window where the OS recycles that pid for
        # this fresh process and the worker loop mistakes the new turn for the
        # interrupted one.
        session.update!(
          metadata: (session.metadata || {}).except("interrupt_terminate_pid").merge(
            "process_pid" => process_pid,
            "runtime_started" => true
          )
        )

        # Now that process_pid is stored, transition to running (unless clone-only).
        # Use start! for the normal waiting->running path. If the session was
        # externally moved to needs_input (e.g., CleanupOrphanedSessionsJob ran
        # between session creation and process spawn), fall back to resume! to
        # recover. Without this, the monitoring loop would see needs_input and
        # immediately exit, leaving the just-spawned process orphaned.
        unless clone_only
          if session.may_start?
            session.start!
          elsif session.may_resume?
            log_buffer.add(
              "Session was externally moved to #{session.status} before process spawn — re-transitioning to running",
              level: "warning"
            )
            session.resume!
          end
        end

        log_buffer.add(
          "[DIAGNOSTIC] Exiting #{runtime_label} CLI spawn block - process spawned successfully",
          level: "debug"
        )
        log_buffer.flush  # Flush process spawn logs
      end

      # Start log streaming in background thread
      log_streaming_thread = start_log_streaming(session, process_pid, stderr_log_path, working_directory)

      # Main polling loop - combines process monitoring and transcript polling
      log_buffer.add(
        "[DIAGNOSTIC] Entering main monitoring loop for session #{session_id}, process_pid=#{process_pid}",
        level: "debug"
      )
      log_buffer.add(
        "Transcript polling job enqueued",
        level: "info"
      )

      stderr_position = 0
      mcp_log_positions = {}
      loop_iteration = 0
      last_flush_time = Time.current
      transcript_poll_failures = 0
      # Tracks whether we've already logged entry into an elicitation-blocked wait,
      # so we log it once per block rather than on every 0.5s loop iteration.
      waiting_on_elicitation = false
      last_sigterm_retry_at = session.metadata&.dig("last_sigterm_at") ? Time.parse(session.metadata["last_sigterm_at"]) : nil
      last_api_error_retry_at = session.metadata&.dig("last_api_error_retry_at") ? Time.parse(session.metadata["last_api_error_retry_at"]) : nil

      loop do
        loop_iteration += 1
        # 1. Check if session was archived or paused externally
        session.reload
        if session.archived?
          log_buffer.add(
            "Session archived, terminating process",
            level: "info"
          )
          log_buffer.flush
          terminate_process(session, process_pid, clone_path, log_buffer)
          cleanup_clone(session, clone_path, log_buffer)
          return
        end

        # 1a. Honor an explicit cross-container interrupt-termination request.
        #
        # In production the web process cannot signal this worker's Claude CLI
        # child: web (Puma) and worker (GoodJob) run in separate containers with
        # separate PID namespaces, so a web-side Process.kill can never reach the
        # process. Sessions::InterruptService therefore records the pid it wants
        # terminated in metadata["interrupt_terminate_pid"]; this loop — running
        # in the worker, the only actor that can actually signal the process —
        # honors it here.
        #
        # This is checked independently of the needs_input branch below because an
        # interrupt resumes the session back to running within the same web
        # request (needs_input -> running, microseconds apart), so the worker can
        # NOT rely on catching the transient needs_input state. The pid scope
        # guarantees we only ever kill the exact turn the interrupt targeted; the
        # interrupting turn spawns with a different pid and is never affected.
        #
        # This flag is a best-effort FAST PATH. session.metadata is a
        # read-modify-write JSON blob written from multiple places, so the flag
        # can in principle be clobbered before we read it. The guarantee against
        # orphaning a superseded turn lives in the running_job_id ownership
        # backstop (branch 1c) below. Compare pids numerically because metadata
        # round-trips through JSON and can hold either an Integer or a String.
        interrupt_pid = session.metadata&.dig("interrupt_terminate_pid")
        if process_pid && interrupt_pid && interrupt_pid.to_i == process_pid.to_i
          log_buffer.add(
            "Interrupt requested termination of the current turn (PID #{process_pid}); " \
            "terminating it so the interrupting turn can take over",
            level: "info"
          )
          log_buffer.flush
          # Clear the request first so it can't outlive this turn (a future turn
          # has a different pid and must never match a stale flag).
          clear_interrupt_terminate_request(session, process_pid)
          # Release our running_job_id only if we still own it — pause! usually
          # cleared it and the interrupting job may already own it; never clobber.
          session.update!(running_job_id: nil) if session.running_job_id == job_id
          # Final transcript poll before we kill the process, mirroring the
          # needs_input exit below: capture any in-flight assistant message the
          # interrupted turn wrote after the last poll so it isn't lost.
          poll_and_broadcast_transcript(session)
          # terminate_process runs in the worker's PID namespace and escalates
          # SIGTERM -> SIGKILL within a bounded window, so a turn that ignores
          # SIGTERM is still reliably killed. We do NOT clean the clone: the
          # interrupting turn reuses it.
          terminate_process(session, process_pid, clone_path, log_buffer)
          return
        end

        # 1b. Check if session was paused externally (user clicked Pause or sent follow-up)
        # When the session transitions to needs_input, we should exit the monitoring loop
        # but first do a final transcript poll to ensure we capture any messages
        # that were written after the last poll and before the process was terminated.
        if session.needs_input?
          # Elicitation block is a SPECIAL needs_input: the agent process is
          # deliberately kept alive (block_on_elicitation skips cleanup_running_job)
          # so the in-flight MCP tool call stays open while the user answers. We must
          # keep supervising that live process — do NOT break here. If the job exits
          # while the process is still running, the `ensure` block terminates it,
          # killing its child MCP subprocess and surfacing the pending tool call to
          # the client as `-32000 Connection closed` (issue #4561). Instead we keep
          # looping; when the elicitation resolves (or expires), the after_commit
          # reconciliation fires unblock_from_elicitation (needs_input -> running),
          # this loop's next reload sees running, and monitoring resumes seamlessly
          # so the original tool call completes normally.
          if session.blocked_on_elicitation?
            unless waiting_on_elicitation
              log_buffer.add(
                "Session blocked on MCP elicitation — keeping agent process alive while awaiting user response",
                level: "info"
              )
              log_buffer.flush
              waiting_on_elicitation = true
            end
            # Detect a dead agent process while blocked. The keep-alive branch
            # deliberately skips section 2's liveness check (wait_nonblock) so it can
            # keep the process alive across the wait — but that also means a crashed
            # agent would otherwise be busy-polled until the elicitation expires (up
            # to ~10 min) before anything noticed. If the process has died, the
            # in-flight MCP tool call is already lost, so stop supervising and break
            # to the ensure path (whose guard leaves the already-dead process alone).
            # The session stays needs_input; elicitation expiry + orphan recovery
            # reconcile it from there.
            unless process_running?(process_pid)
              log_buffer.add(
                "Agent process #{process_pid} died while blocked on MCP elicitation — exiting monitoring loop; recovery will reconcile the session",
                level: "warning"
              )
              log_buffer.flush
              remove_running_loader(session)
              break
            end
            # Keep the transcript fresh and flush buffered logs periodically so the
            # elicitation-wait window isn't a monitoring/logging black hole. A human
            # is answering a prompt here, so poll on a relaxed cadence rather than the
            # sub-second interval used for active monitoring.
            poll_and_broadcast_transcript(session)
            if (Time.current - last_flush_time) >= 10
              log_buffer.flush
              last_flush_time = Time.current
            end
            sleep 2
            next
          end

          log_buffer.add(
            "Session paused externally, doing final transcript poll before exit",
            level: "info"
          )

          # Do one final transcript poll to capture any in-flight messages
          # This ensures the most recent Claude message is displayed even when
          # the user pauses the session while Claude is in the middle of writing
          poll_and_broadcast_transcript(session)

          log_buffer.flush

          # Clear running_job_id immediately to prevent duplicate polling if a new job starts.
          # This fixes Bug #550 where old and new jobs could poll simultaneously during
          # the pause + follow-up transition. The running_job_id check at job start (line ~166)
          # relies on this being cleared promptly.
          session.update!(running_job_id: nil)

          remove_running_loader(session)
          log_buffer.add(
            "[DIAGNOSTIC] Exiting monitoring loop - session paused externally",
            level: "debug"
          )
          break
        end

        # 1c. Ownership backstop. If another job now owns this session
        # (running_job_id changed out from under us) while we are still running,
        # our turn has been superseded — terminate our process and exit so we
        # never orphan it on the shared clone.
        #
        # This is the GENERAL guarantee that makes the interrupt_terminate_pid
        # flag (branch 1a) a best-effort fast path rather than the sole
        # mechanism: even if that flag is lost, wiped, or clobbered by a
        # concurrent metadata write, a superseding job reclaims running_job_id
        # and this check reliably ends the old turn. It also covers the
        # pre-existing case where a later job supersedes a stale lock without a
        # pause. nil is treated as "not superseded" (pause! clears running_job_id
        # on a legitimate exit handled by branch 1b), so a transient nil never
        # triggers a spurious kill.
        if session.running_job_id.present? && session.running_job_id != job_id
          log_buffer.add(
            "Session ownership moved to job #{session.running_job_id} (this job is #{job_id}); " \
            "terminating superseded turn (PID #{process_pid}) to avoid orphaning it",
            level: "info"
          )
          log_buffer.flush
          # Clear any interrupt request we may have been the target of so it can't
          # outlive us and match a future turn's (different) pid.
          clear_interrupt_terminate_request(session, process_pid)
          # Final poll before terminating, mirroring branches 1a/1b.
          poll_and_broadcast_transcript(session)
          # Do NOT clean the clone — the superseding turn reuses it.
          terminate_process(session, process_pid, clone_path, log_buffer)
          return
        end

        # Reaching here means the session is running (not needs_input). If we were
        # previously in an elicitation-blocked wait, it has now resolved — clear the
        # flag so a subsequent elicitation in the same turn logs its wait afresh.
        waiting_on_elicitation = false

        # 2. Check if process is still running using ProcessLifecycleManager
        # This must happen BEFORE timeout check to avoid marking completed sessions as failed
        wait_result = lifecycle_manager.wait_nonblock
        if wait_result
          pid, status = wait_result

          # Process has exited - do one final transcript poll
          poll_and_broadcast_transcript(session)

          # Use ProcessLifecycleManager to handle the exit decision
          # This encapsulates SIGTERM retry, context length recovery, etc.
          unless session.archived?
            exit_decision = lifecycle_manager.handle_exit(status, working_dir: working_directory)

            case exit_decision.action
            when :continue
              # Retry was successful - continue monitoring the new process
              # Update local variables from session metadata (retry service stored new PID there)
              session.reload
              process_pid = session.metadata&.dig("process_pid")
              stderr_log_path = File.join(clone_path, "claude_stderr.log") if clone_path
              # Update retry timestamps to track successful run duration for reset logic
              last_sigterm_retry_at = Time.current
              last_api_error_retry_at = Time.current
              # Restart log streaming thread for new process
              log_streaming_thread&.kill if log_streaming_thread&.alive?
              log_streaming_thread = start_log_streaming(session, process_pid, stderr_log_path, working_directory)
              # Continue the loop with the new process
              next
            when :needs_input
              quota_limited = exit_decision.error_message&.include?("Account quota limit")
              if quota_limited
                log_buffer.add(
                  "Session paused: #{exit_decision.error_message}",
                  level: "warning"
                )
                session.update!(
                  metadata: (session.metadata || {}).merge(
                    "exit_status" => exit_decision.error_message
                  )
                )
              else
                log_buffer.add(
                  "#{runtime_label} CLI completed turn successfully",
                  level: "info"
                )
              end
              # Try to hand off to a queued message BEFORE pausing — if a message
              # is ready, the session stays running while the next AgentSessionJob
              # takes over. This avoids a transient running → needs_input → running
              # flap that fires ao_event watchers (e.g., session_needs_input wakes)
              # and other one-shot subscribers spuriously.
              # Skip if quota-limited — sending another message would just fail again.
              if !quota_limited && process_next_enqueued_message_if_available(session, log_buffer)
                # A new job was enqueued to process the message, exit this job
                log_buffer.add(
                  "Enqueued message being processed, exiting current job (handoff path — no pause flap)",
                  level: "info"
                )
                log_buffer.flush
                return
              end
              session.pause! if session.may_pause?
              # Broadcast status immediately for snappy UI updates (don't wait for after_update_commit)
              @broadcast_service.session_status(session)
            when :failed
              log_buffer.add(
                "#{runtime_label} CLI failed: #{exit_decision.error_message}",
                level: "error"
              )
              # Map error messages to specific failure reasons
              failure_reason = case exit_decision.error_message
              when /SIGTERM retry limit exhausted/i
                "sigterm_retries_exhausted"
              when /Context length compact limit exhausted/i
                "context_length_compact_failed"
              when /API error retry limit exhausted/i
                "api_error_retries_exhausted"
              when /Clone directory no longer exists/i
                # Benign terminal case: the clone was GC'd after the session was torn
                # down, so a continuation re-spawn is impossible (not a system fault).
                "clone_removed"
              else
                "process_failed"
              end
              session.update!(
                metadata: (session.metadata || {}).merge(
                  "failure_reason" => failure_reason,
                  "exit_status" => exit_decision.error_message
                )
              )
              session.fail! if session.may_fail?
            when :aborted
              # Session status changed (e.g., user paused) - just log and exit
              log_buffer.add(
                "Exit handling aborted - session status changed",
                level: "info"
              )
            end
          end

          # Remove the running loader when session completes
          remove_running_loader(session)
          log_buffer.add(
            "[DIAGNOSTIC] Exiting monitoring loop - process exited normally",
            level: "debug"
          )
          break
        end

        # 3. Fallback process detection using signal 0 (handles zombie processes)
        # Process.wait may not detect exit if the process became a zombie
        unless lifecycle_manager.running?
          log_buffer.add(
            "Process #{process_pid} no longer running (detected via signal check)",
            level: "warning"
          )
          # Do one final transcript poll
          poll_and_broadcast_transcript(session)
          # Try to hand off to a queued message BEFORE pausing to avoid a
          # running → needs_input → running flap that fires ao_event watchers
          # spuriously (see comment at the :needs_input exit-decision branch).
          # Don't remove the running loader on the handoff path — the session
          # stays running and the new job will keep the loader visible.
          if process_next_enqueued_message_if_available(session, log_buffer)
            log_buffer.add(
              "Enqueued message being processed, exiting current job (handoff path — no pause flap)",
              level: "info"
            )
            log_buffer.flush
            return
          end
          session.pause! if session.may_pause?
          # Broadcast status immediately for snappy UI updates (don't wait for after_update_commit)
          @broadcast_service.session_status(session)
          remove_running_loader(session)
          log_buffer.add(
            "[DIAGNOSTIC] Exiting monitoring loop - process no longer running (signal check)",
            level: "debug"
          )
          break
        end

        # 4. Poll transcript file and broadcast updates (track failures)
        # poll_result can be:
        #   - true: successfully polled and processed transcript
        #   - false: error occurred (exception or missing working_directory)
        #   - nil: waiting state (transcript directory or files not yet created)
        poll_result = poll_and_broadcast_transcript(session)
        if poll_result == false
          transcript_poll_failures += 1
          if transcript_poll_failures >= MAX_TRANSCRIPT_POLL_FAILURES
            log_buffer.add(
              "Transcript polling failed #{transcript_poll_failures} times consecutively",
              level: "error"
            )
            log_buffer.flush
            session.update!(
              metadata: (session.metadata || {}).merge("failure_reason" => "transcript_unavailable")
            )
            session.fail! if session.may_fail?
            remove_running_loader(session)
            log_buffer.add(
              "[DIAGNOSTIC] Exiting monitoring loop - transcript poll failures exceeded threshold",
              level: "debug"
            )
            break
          end
        elsif poll_result == true
          # Only reset failure count on explicit success, not on waiting (nil)
          # nil indicates expected waiting state (directory/files not yet created)
          transcript_poll_failures = 0
        end
        # If poll_result is nil, don't change the counter (waiting state is neutral)

        # 4b. Check if MCP connection failure was detected by transcript hook
        # The McpConnectionFailureHook sets should_fail_session in custom_metadata
        # when configured MCP servers fail to connect
        if check_and_handle_mcp_failure(session, process_pid, clone_path, log_buffer)
          # MCP failure detected and handled - exit the monitoring loop
          break
        end

        # 4c. Check if Claude CLI is hung after emitting "Prompt is too long" as a regular
        # assistant message. The process stays alive but idle in this case. Terminate it
        # and let handle_exit route to compact recovery on the next loop iteration.
        if check_and_handle_prompt_too_long_hang(session, process_pid, log_buffer)
          next
        end

        # 5. Reset retry counters if process has been running successfully
        # for SIGTERM_RETRY_RESET_THRESHOLD seconds since the last retry.
        # This prevents premature failure when multiple errors are separated by
        # periods of successful operation (see issue #459).
        check_and_reset_sigterm_retry_counter(session, last_sigterm_retry_at, log_buffer)
        check_and_reset_api_error_retry_counter(session, last_api_error_retry_at, log_buffer)

        # 6. Check for fallback: end_turn + dead process
        # This should rarely trigger now that we're in the same job,
        # but keep it as a safety mechanism
        check_and_update_status_if_turn_completed(session, process_pid, log_buffer)

        # 7. Periodic flush every 10 seconds (time-based, not iteration-based)
        if (Time.current - last_flush_time) >= 10
          log_buffer.flush
          last_flush_time = Time.current
        end

        # 8. Sleep before next iteration
        # Poll every 0.5 seconds for snappy state transitions when agent completes.
        # Process exit detection via wait_nonblock is very cheap (non-blocking syscall),
        # and the main work (transcript polling) only happens when there are changes.
        sleep 0.5
      end

      job_type = follow_up_prompt.present? ? "Follow-up" : "Session"
      log_buffer.add(
        "#{job_type} job completed successfully",
        level: "info"
      )
      log_buffer.add(
        "[DIAGNOSTIC] Job completing normally for session #{session_id}",
        level: "debug"
      )
      log_buffer.flush

      # Clear running_job_id on successful completion
      session.update!(running_job_id: nil)

    # NOTE: GoodJob::InterruptError is NOT caught here. GoodJob's InterruptErrors
    # extension raises it in an around_perform callback BEFORE perform() runs,
    # so it never reaches this rescue chain. Instead, it's handled by the
    # rescue_from callback at the class level (see handle_interrupt_error above).

    rescue => e
      if session
        log_buffer.add(
          "Error in agent execution: #{e.message}",
          level: "error"
        )
        log_buffer.add(
          "Backtrace: #{e.backtrace.first(5).join("\n")}",
          level: "error"
        )
        log_buffer.flush
        # Bypass validations — if the original error was a validation failure
        # (e.g. stale MCP server catalog), update! would re-trigger the same
        # validation and prevent the session from reaching a terminal state.
        session.update_columns(
          running_job_id: nil,
          metadata: (session.metadata || {}).merge(
            "failure_reason" => "exception",
            "exception_class" => e.class.name,
            "exception_message" => e.message.to_s.truncate(EXCEPTION_MESSAGE_MAX_CHARS)
          )
        )
        session.reload
        session.fail! if session.may_fail?
      end
      raise e
    ensure
      # Flush any remaining logs first
      log_buffer.flush if log_buffer&.any?
      # Stop log streaming thread
      if log_streaming_thread
        log_streaming_thread.kill if log_streaming_thread.alive?
        log_streaming_thread.join(1)
      end

      # Only cleanup if session is in a terminal state
      # Don't cleanup for needs_input (includes paused sessions waiting for follow-up)
      if session
        session.reload
        if session.archived?
          # Only cleanup when explicitly archived by the user
          terminate_process(session, process_pid, clone_path, log_buffer) if process_pid
          cleanup_clone(session, clone_path, log_buffer) if clone_path
        elsif session.failed?
          # Preserve clone on failure for debugging and recovery
          # Only terminate the process if it's still running
          terminate_process(session, process_pid, clone_path, log_buffer) if process_pid && process_running?(process_pid)
          # Log the preserved clone path for user reference
          if clone_path
            log_buffer.add(
              "Clone preserved for debugging: #{clone_path}. Archive this session to cleanup the clone directory.",
              level: "info"
            )
            log_buffer.flush
          end
        elsif session.needs_input?
          # Session is paused or waiting for follow-up - preserve clone for resume.
          # Only terminate the process if it's still running.
          #
          # EXCEPTION: a session blocked on a pending MCP elicitation reaches
          # needs_input with its agent process intentionally still alive, holding
          # the in-flight MCP tool call open. Terminating it here would kill the
          # child MCP subprocess and surface the pending call as `-32000 Connection
          # closed` (issue #4561). The monitoring loop keeps supervising this case
          # and normally never exits while blocked, so this branch is only reached
          # on an abnormal early exit (e.g. an unexpected exception). In that case
          # we leave the process alive: recovery will re-attach a monitoring job,
          # preserving the elicitation round-trip across the blip.
          if process_pid && process_running?(process_pid) && !session.blocked_on_elicitation?
            terminate_process(session, process_pid, clone_path, log_buffer)
          end
        end
      end
    end
  end

  private

  # Attempt to recover from a transient git clone failure during session startup
  # by re-enqueuing the whole job on a backed-off horizon, instead of hard-failing
  # the session. Returns true if a retry was scheduled (the caller should stop and
  # return), false if the job-level retry budget is exhausted (the caller should
  # fall through to its normal failure handling).
  #
  # The session is left in place — "waiting" on the startup path (the waiting →
  # running transition only happens after a process spawns, which never occurred),
  # "running" on the follow-up path — with running_job_id pointed at the newly
  # scheduled retry job. CleanupOrphanedSessionsJob skips "waiting" sessions
  # entirely, and for the "running" follow-up case it treats the session as alive
  # because clone_retry_count is set and running_job_id points at a future-scheduled,
  # unfinished job. The retry count lives in metadata so it survives across job runs
  # and is reset by the caller once a clone finally succeeds.
  #
  # @param session [Session]
  # @param error [Exception] the transient clone failure
  # @param log_buffer [LogBuffer]
  # @param kind [String] "startup" or "follow-up", for the log line
  # @yield [Integer] the delay in seconds; the block must enqueue the retry job and
  #   return the enqueued job (responding to #job_id)
  # @return [Boolean]
  def schedule_transient_clone_retry(session, error, log_buffer, kind:)
    attempts = session.metadata&.dig("clone_retry_count").to_i

    if attempts >= MAX_CLONE_JOB_RETRIES
      log_buffer.add(
        "Git clone failed transiently (#{kind}) after #{attempts} automatic retries — giving up: #{error.message}",
        level: "error"
      )
      return false
    end

    next_attempt = attempts + 1
    delay = CLONE_JOB_RETRY_DELAYS_SECONDS[[ next_attempt - 1, CLONE_JOB_RETRY_DELAYS_SECONDS.length - 1 ].min]

    log_buffer.add(
      "Git clone failed transiently (#{kind}); scheduling automatic retry #{next_attempt}/#{MAX_CLONE_JOB_RETRIES} in #{delay}s: #{error.message}",
      level: "info"
    )
    log_buffer.flush

    session.update!(
      metadata: (session.metadata || {}).merge("clone_retry_count" => next_attempt)
    )

    retry_job = yield(delay)

    # Point the session at the scheduled retry job so orphan detection sees a live
    # (future-scheduled) job and leaves the session alone until the retry runs.
    session.update!(running_job_id: retry_job.job_id)
    true
  end

  # Handle GoodJob::InterruptError raised by the InterruptErrors extension.
  #
  # This runs as a rescue_from callback when a job is retried after worker shutdown.
  # The InterruptError is raised in GoodJob's around_perform hook BEFORE perform()
  # runs, so this is the only place we can intercept it for session state management.
  #
  # Pauses the session to needs_input, then immediately auto-continues it by
  # re-enqueuing a new job with a recovery prompt. This avoids a ~5 minute delay
  # that would occur if we waited for CleanupOrphanedSessionsJob to pick it up.
  #
  # If auto-continue fails, the session stays in needs_input with paused_by: "recovery"
  # so DeploymentRecoveryJob or CleanupOrphanedSessionsJob can recover it as a safety net.
  def handle_interrupt_error(error)
    session_id = arguments.first
    return unless session_id

    session = Session.find_by(id: session_id)
    return unless session

    Rails.logger.info "[AgentSessionJob] Handling InterruptError for session #{session_id}: #{error.message}"

    session.logs.create!(
      content: "Job interrupted by worker shutdown (deploy): #{error.message}",
      level: "warning"
    )

    session.update_columns(
      running_job_id: nil,
      metadata: (session.metadata || {}).merge("paused_by" => "recovery")
    )
    session.reload

    if session.may_pause?
      session.pause!
    elsif session.waiting? && session.may_start?
      # Session was still in waiting state (interrupt arrived before process spawn).
      # Transition through running to needs_input so recovery can pick it up.
      session.start!
      session.pause! if session.may_pause?
    end

    Rails.logger.info "[AgentSessionJob] Session #{session_id} paused for deploy recovery (status: #{session.status})"

    # Immediately auto-continue: re-enqueue the job so the session resumes
    # within seconds instead of waiting for the 5-minute cleanup cron.
    auto_continue_after_interrupt(session)
  rescue => e
    # Don't let recovery errors prevent the job from being discarded.
    # DeploymentRecoveryJob/CleanupOrphanedSessionsJob will catch orphaned sessions as a safety net.
    Rails.logger.error "[AgentSessionJob] Error handling InterruptError for session #{session_id}: #{e.message}"
  end

  # Attempt to immediately auto-continue a session after InterruptError.
  # Validates the session is resumable, clears stale metadata, transitions to
  # running, and enqueues a new job with a recovery prompt.
  #
  # If this fails for any reason, the session remains in needs_input with
  # paused_by: "recovery" for the cron-based recovery to handle.
  def auto_continue_after_interrupt(session)
    require "automated_prompts"

    unless session.needs_input?
      Rails.logger.warn "[AgentSessionJob] Cannot auto-continue session #{session.id}: not in needs_input (#{session.status})"
      return
    end

    unless session.session_id.present?
      Rails.logger.warn "[AgentSessionJob] Cannot auto-continue session #{session.id}: no session_id"
      return
    end

    working_directory = session.metadata&.dig("working_directory")
    unless working_directory.present? && Dir.exist?(working_directory)
      Rails.logger.warn "[AgentSessionJob] Cannot auto-continue session #{session.id}: working directory not found"
      return
    end

    ActiveRecord::Base.transaction do
      session.update!(
        running_job_id: nil,
        metadata: (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)
      )

      session.resume! if session.may_resume?

      AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)

      session.logs.create!(
        content: "Session automatically continued after deploy interruption",
        level: "info"
      )
    end

    Rails.logger.info "[AgentSessionJob] Session #{session.id} auto-continued after deploy interruption"
  rescue => e
    Rails.logger.error "[AgentSessionJob] Failed to auto-continue session #{session.id}: #{e.message}. " \
                        "Session remains in needs_input for cron-based recovery."
  end

  # Validate session state before attempting to resume Claude CLI session
  # @param session [Session] The session to validate
  # @param clone_path [String] The path to the clone directory
  # @return [Hash] { valid: Boolean, reason: String, warning: String }
  #
  # Hard requirements (will fail validation):
  # - session_id must exist and be valid UUID format
  # - clone directory must exist and be accessible
  #
  # Soft requirements (will warn but continue):
  # - resume transcript file missing/empty (we already have most history in session.transcript from polling)
  def validate_session_for_resume(session, clone_path)
    # Validate session_id exists and is valid UUID format
    unless session.session_id.present?
      return { valid: false, reason: "session_id is missing" }
    end

    # Validate UUID format (8-4-4-4-12 hexadecimal pattern)
    uuid_pattern = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    unless session.session_id.match?(uuid_pattern)
      return { valid: false, reason: "session_id is not a valid UUID format" }
    end

    # Check clone directory exists and is accessible
    unless @file_system.exists?(clone_path)
      return { valid: false, reason: "clone directory not found at #{clone_path}" }
    end

    # Verify clone directory is accessible
    unless @file_system.readable?(clone_path)
      return { valid: false, reason: "clone directory not accessible at #{clone_path}" }
    end

    # Soft check - transcript cache is nice-to-have, not required
    # We already have most history in session.transcript from polling (every ~5 seconds)
    # At most ~5 seconds of messages could be missing if cache was cleared
    # Claude CLI will create new transcript files when it resumes
    working_directory = session.metadata&.dig("working_directory") || clone_path
    transcript_path = transcript_file_path(session, working_directory)
    warning = nil

    # Runtimes without single-file transcript restore (e.g. Codex) have no path
    # to check here; the soft check simply doesn't apply.
    return { valid: true, reason: nil, warning: nil } if transcript_path.nil?

    unless @file_system.exists?(transcript_path)
      warning = "Resume transcript file missing (a few recent messages may be lost): #{transcript_path}"
    else
      begin
        transcript_content = @file_system.read(transcript_path)
        if transcript_content.strip.empty?
          warning = "Resume transcript file is empty (a few recent messages may be lost): #{transcript_path}"
        end
      rescue => e
        warning = "Failed to read resume transcript file (a few recent messages may be lost): #{e.message}"
      end
    end

    { valid: true, reason: nil, warning: warning }
  end

  # Calculate the on-disk transcript file the runtime reads on `--resume`.
  #
  # Delegates to the runtime's TranscriptSource so the path matches exactly where
  # the CLI reads/writes (for Claude Code, ~/.claude/projects/<sanitized-cwd>/
  # <session_id>.jsonl). It must NOT point at the CLI cache directory
  # (~/.cache/claude-cli-nodejs), which holds MCP logs — writing a restored
  # transcript there leaves the real resume file untouched, so `--resume` reads a
  # truncated conversation and silently drops the user's prompt.
  #
  # @param session [Session] The session
  # @param working_directory [String] The working directory path
  # @return [String, nil] The transcript file path, or nil for runtimes that do
  #   not support single-file transcript restore (e.g. Codex)
  def transcript_file_path(session, working_directory)
    TranscriptRuntime.source_for(session, file_system: @file_system)
      .resume_transcript_path(session: session, working_directory: working_directory)
  end

  # Write session transcript to a clone's Claude Code project directory so the
  # CLI can resume the conversation. Mirrors UnarchiveSessionService#write_transcript_file.
  def write_transcript_to_clone(session, working_directory, log_buffer = nil)
    path = transcript_file_path(session, working_directory)
    return if path.nil?
    @file_system.mkdir_p(File.dirname(path))
    @file_system.write(path, session.transcript)
  rescue => e
    msg = "Failed to write transcript for session #{session.id}: #{e.message}"
    if log_buffer
      log_buffer.add(msg, level: "warning")
    else
      Rails.logger.warn "[AgentSessionJob] #{msg}"
    end
  end

  # Restore the clone's on-disk transcript from the canonical stored transcript
  # when the on-disk copy is missing or has regressed (fewer events than the
  # stored record). The runtime resumes from the on-disk <session_id>.jsonl, so a
  # truncated file makes --resume operate on a partial conversation and no-op back
  # to needs_input. The stored transcript is the durable, never-shrinking record
  # (TranscriptPollerService refuses to overwrite it with a shorter one), so it is
  # the correct source of truth to re-materialize on disk before a resume.
  #
  # @return [Boolean] true when the on-disk transcript is safe to resume from —
  #   it was already whole, the runtime opts out of single-file restore (e.g.
  #   Codex), or the stored transcript was successfully re-materialized and
  #   verified. false when a regression was detected but could NOT be repaired on
  #   disk; the caller MUST fail loud rather than resume into a silent no-op that
  #   drops the user's prompt.
  def restore_regressed_transcript_if_needed(session, working_directory, log_buffer = nil)
    return true unless session.transcript.present? && session.session_id.present?

    path = transcript_file_path(session, working_directory)
    # Runtimes without single-file restore (e.g. Codex) opt out; nothing to repair.
    return true if path.nil?

    on_disk = @file_system.exists?(path) ? @file_system.read(path) : nil
    return true unless on_disk.nil? || Session.transcript_regression?(session.transcript, on_disk)

    write_transcript_to_clone(session, working_directory, log_buffer)

    # write_transcript_to_clone swallows IO errors, so confirm the restore
    # actually landed and is no longer regressed before trusting the resume. A
    # silent write failure must not be mistaken for a repair — otherwise we would
    # clear the regression marker and resume a truncated conversation.
    repaired = @file_system.exists?(path) ? @file_system.read(path) : nil
    if repaired.nil? || Session.transcript_regression?(session.transcript, repaired)
      msg = "Failed to restore regressed transcript on disk before resume (path: #{path})"
      if log_buffer
        log_buffer.add(msg, level: "error")
      else
        Rails.logger.error "[AgentSessionJob] #{msg}"
      end
      return false
    end

    detail = on_disk.nil? ? "missing" : "regressed to #{Session.transcript_line_count(on_disk)} of #{Session.transcript_line_count(session.transcript)} events"
    msg = "Restored stored transcript to clone before resume (on-disk copy was #{detail})"
    if log_buffer
      log_buffer.add(msg, level: "warning")
    else
      Rails.logger.warn "[AgentSessionJob] #{msg}"
    end

    # Clear the poller's regression marker now that the on-disk copy is whole again.
    if session.metadata&.dig("transcript_regression_detected")
      with_db_retry do
        session.update!(metadata: session.metadata.except("transcript_regression_detected"))
      end
    end
    true
  end

  # Build spawn options for the Claude CLI process
  def build_spawn_options(working_directory, stderr_log_path)
    {
      chdir: working_directory,
      out: stderr_log_path,
      err: [ :child, :out ],
      pgroup: true
    }
  end

  # Monitor process completion
  def monitor_process_completion(pid)
    loop do
      pid, status = @process_manager.wait(pid, Process::WNOHANG)
      return status if pid
      sleep 1
    end
  end

  # Cleanup on failure
  def cleanup_on_failure(session, process_pid, clone_path, log_buffer)
    terminate_process(session, process_pid, clone_path, log_buffer) if process_pid
    cleanup_clone(session, clone_path, log_buffer) if clone_path
  end

  # Poll the transcript file and broadcast new messages
  # Returns true on success, false on error, nil on waiting state
  def poll_and_broadcast_transcript(session)
    # Skip polling if another job has taken over this session (Bug #550)
    # This prevents duplicate broadcasts during job transitions
    session.reload
    if session.running_job_id.present? && session.running_job_id != job_id
      Rails.logger.debug "[AgentSessionJob] Skipping transcript poll - another job (#{session.running_job_id}) owns this session"
      return nil  # Return nil (waiting) to avoid incrementing failure counter
    end

    poller = TranscriptPollerService.new(
      session,
      file_system: @file_system,
      broadcast_service: @broadcast_service
    )
    poller.poll_and_broadcast
  end

  # Remove the running loader when session completes
  def remove_running_loader(session)
    Rails.logger.debug "[AgentSessionJob] Removing running loader for session #{session.id}"

    # Delegate to BroadcastService for consistent error handling and retry logic
    @broadcast_service.remove_running_loader(session)
  end

  # Check for and process the next enqueued message if available
  #
  # Delegates to EnqueuedMessageProcessorService for the actual processing.
  # This method is called after a session transitions to needs_input state.
  #
  # @param session [Session] The session to check for enqueued messages
  # @param log_buffer [LogBuffer] Buffer for logging
  # @return [Boolean] true if a message was processed, false otherwise
  def process_next_enqueued_message_if_available(session, log_buffer)
    processor = EnqueuedMessageProcessorService.new(session, log_buffer: log_buffer, broadcast_service: @broadcast_service)
    processor.process_next_message
  end

  # Check if Claude has finished a turn and update status if needed
  # Fallback mechanism when process monitoring fails
  def check_and_update_status_if_turn_completed(session, process_pid, log_buffer)
    return unless session.running?
    return unless process_pid

    # Get messages from transcript. parsed_transcript routes through the
    # session's runtime transcript source, so turn detection stays
    # runtime-agnostic alongside the rest of the transcript pipeline.
    messages = session.parsed_transcript
    return if messages.empty?

    # Find the last assistant message in the transcript.
    # Claude CLI may append non-assistant entries (e.g., queue-operation/dequeue)
    # after the final assistant message, so checking only messages.last would miss
    # completed turns and leave sessions stuck in "running".
    last_assistant = messages.reverse_each.find { |m| m["type"] == "assistant" }
    return unless last_assistant

    # Check if the last assistant message completed its turn
    stop_reason = last_assistant.dig("message", "stop_reason")

    if stop_reason == "end_turn"
      # Check if the Claude CLI process has exited
      begin
        @process_manager.getpgid(process_pid)
        # Process is still running, don't update status yet
        Rails.logger.debug "[AgentSessionJob] Claude finished turn but process #{process_pid} still running"
      rescue Errno::ESRCH
        # Process is not running - this means the turn is complete
        Rails.logger.info "[AgentSessionJob] Detected completed turn with exited process #{process_pid}, updating status to needs_input"

        # Try to hand off to a queued message BEFORE pausing to avoid a
        # running → needs_input → running flap that fires ao_event watchers
        # spuriously (see comment at the :needs_input exit-decision branch).
        # Don't remove the running loader on the handoff path — the session
        # stays running and the new job will keep the loader visible.
        if process_next_enqueued_message_if_available(session, log_buffer)
          log_buffer.add(
            "Turn completed - enqueued message being processed (handoff path — no pause flap)",
            level: "info"
          )
          log_buffer.flush
          return
        end

        session.pause! if session.may_pause?
        # Broadcast status immediately for snappy UI updates (don't wait for after_update_commit)
        @broadcast_service.session_status(session)
        remove_running_loader(session)

        log_buffer.add(
          "Turn completed - ready for follow-up prompt",
          level: "info"
        )

        log_buffer.flush
      end
    end
  rescue => e
    Rails.logger.error "[AgentSessionJob] Error checking turn completion: #{e.message}"
  end

  # Maximum number of automatic retries for transient MCP connection failures.
  # After this many attempts, the session permanently fails.
  # Total wait time: 30s + 60s + 120s = 210s (~3.5 minutes)
  MAX_MCP_CONNECTION_RETRIES = 3

  # Base delay (in seconds) for the first MCP retry. Subsequent retries
  # double: 30s, 60s, 120s. This gives MCP servers time to start after a deploy.
  MCP_RETRY_BASE_DELAY = 30

  # Check if MCP connection failure was detected by transcript hook and handle it
  #
  # The McpConnectionFailureHook analyzes the system init message in the transcript
  # and sets should_fail_session=true in custom_metadata when configured MCP servers
  # fail to connect (status: "error", "offline", or not found).
  #
  # When MCP failure is detected:
  # 1. Log the failure details
  # 2. Terminate the Claude CLI process
  # 3. For non-OAuth failures: retry with exponential backoff (up to MAX_MCP_CONNECTION_RETRIES)
  # 4. On final retry or OAuth failure: transition to failed state
  #
  # MCP connection failures are often transient — especially during deploys, where
  # the auto-recovery system restarts sessions before MCP servers have finished
  # starting. Retrying with backoff (30s, 60s, 120s) gives MCP servers time to
  # come online without requiring manual intervention.
  #
  # @param session [Session] The current session
  # @param process_pid [Integer] The Claude CLI process PID
  # @param clone_path [String] Path to the clone directory
  # @param log_buffer [LogBuffer] Buffer for logging
  # @return [Boolean] true if MCP failure was detected and handled, false otherwise
  def check_and_handle_mcp_failure(session, process_pid, clone_path, log_buffer)
    session.reload
    custom_metadata = session.custom_metadata || {}

    # Check if the transcript hook flagged an MCP failure
    return false unless custom_metadata["should_fail_session"] == true

    # Extract failure details
    failed_servers = custom_metadata["mcp_failed_servers"] || []
    failure_reason = custom_metadata["mcp_failure_reason"] || "MCP server connection failed"

    log_buffer.add(
      "MCP connection failure detected: #{failure_reason}",
      level: "error"
    )

    # Log details about each failed server
    failed_servers.each do |server|
      log_buffer.add(
        "MCP server '#{server['name']}' status: #{server['status']}",
        level: "error"
      )
    end

    log_buffer.flush

    # Terminate the Claude CLI process
    terminate_process(session, process_pid, clone_path, log_buffer)

    # Check if any failures are due to OAuth-related errors - these indicate OAuth is required
    # Patterns: "Unauthorized"/"401" (standard auth errors), "Supported scopes" (servers like
    # Tally that report OAuth scopes in the error), "oauth" (generic OAuth error messages)
    oauth_failures = failed_servers.select do |server|
      error = server["error"].to_s
      error.match?(/unauthorized|401|supported scopes|oauth/i)
    end

    if oauth_failures.any?
      # This is an OAuth issue - convert failed servers to oauth_required format
      working_directory = session.metadata&.dig("working_directory")
      oauth_required_servers = oauth_failures.map do |server|
        server_name = server["name"]
        server_config = ServersConfig.find(server_name)
        server_url = server_config&.url

        {
          "server_name" => server_name,
          "server_url" => server_url,
          "error" => server["error"]
        }
      end

      log_buffer.add(
        "OAuth authorization required for: #{oauth_failures.map { |s| s['name'] }.join(', ')}",
        level: "warning"
      )

      session.update!(
        metadata: (session.metadata || {}).merge(
          "failure_reason" => "oauth_required",
          "oauth_required_servers" => oauth_required_servers
        )
      )
    else
      # Regular MCP connection failure (not OAuth related) — retry with backoff
      # MCP failures are often transient (e.g., servers still starting after deploy).

      # Before retrying, heal any corrupt/version-skewed `_npx/<hash>` cache that
      # an `npx -y <pkg>@latest` server blamed for a Node module-resolution error
      # (MODULE_NOT_FOUND or an ESM directory-import/subpath-export failure such as
      # ERR_UNSUPPORTED_DIR_IMPORT). A corrupt cache otherwise sticks (npx treats
      # it as "installed"), so the retry would crash identically; removing the tree
      # forces a fresh, complete install on the next attempt (GitHub issues #3924 / #4109).
      heal_partial_npx_cache(session, failed_servers, log_buffer)

      mcp_retry_count = (session.metadata&.dig("mcp_retry_count") || 0).to_i

      if mcp_retry_count < MAX_MCP_CONNECTION_RETRIES
        return schedule_mcp_retry(session, failed_servers, mcp_retry_count, log_buffer)
      end

      # Max retries exhausted — fall through to permanent failure
      log_buffer.add(
        "MCP connection retry limit exhausted (#{MAX_MCP_CONNECTION_RETRIES} attempts). Failing session.",
        level: "error"
      )

      # Emit the authoritative ERROR to Rails.logger (shipped to obs / VictoriaLogs
      # via the OTLP exporter) ONLY for this terminal case: the session is genuinely
      # orphaned by MCP failure after all retries are exhausted. The intermediate,
      # self-healing detection (McpStatusPersisting) logs at .info so transient flaps
      # don't page on-call — this terminal failure is what the global prod-ERROR
      # alert should fire on. See GitHub issues #3924 / #4109.
      Rails.logger.error(
        "MCP servers failed to connect — session orphaned after #{MAX_MCP_CONNECTION_RETRIES} retries " \
        "| session_id=#{session.id} failed_servers=#{failed_servers.map { |s| s["name"] }.join(",")}"
      )

      session.update!(
        metadata: (session.metadata || {}).merge(
          "failure_reason" => "mcp_connection_failed",
          "mcp_failed_servers" => failed_servers
        )
      )
    end

    session.fail! if session.may_fail?

    # Remove the running loader
    remove_running_loader(session)

    log_buffer.add(
      "[DIAGNOSTIC] Exiting monitoring loop - MCP connection failure detected",
      level: "debug"
    )

    true
  rescue => e
    Rails.logger.error "[AgentSessionJob] Error handling MCP failure: #{e.message}"
    false
  end

  # Remove any partially-populated `_npx/<hash>` cache tree that a failed MCP
  # server blamed for a transitive MODULE_NOT_FOUND, so the next retry installs
  # it cleanly. No-op when the failure isn't an `_npx` module-resolution error.
  #
  # @param session [Session] The current session
  # @param failed_servers [Array<Hash>] entries shaped { "name" =>, "error" => }
  # @param log_buffer [LogBuffer] Buffer for logging
  def heal_partial_npx_cache(session, failed_servers, log_buffer)
    working_directory = session.metadata&.dig("working_directory")
    result = NpxCacheHealService.heal_from_failures(
      failed_servers: failed_servers,
      working_directory: working_directory
    )

    if result[:healed]
      log_buffer.add(
        "Healed corrupt _npx cache (module-resolution failure) before retry — removed: " \
        "#{result[:removed_paths].join(', ')}",
        level: "warning"
      )
    end
  rescue => e
    Rails.logger.error "[AgentSessionJob] Error healing partial npx cache: #{e.message}"
  end

  # Schedule an MCP connection retry with exponential backoff.
  #
  # Instead of permanently failing, transitions the session to needs_input with
  # paused_by: "recovery" and schedules a new job after a delay. This gives MCP
  # servers time to start (e.g., after a deploy) before retrying.
  #
  # Backoff schedule: 30s, 60s, 120s (base * 2^attempt)
  #
  # @param session [Session] The current session
  # @param failed_servers [Array<Hash>] The servers that failed to connect
  # @param mcp_retry_count [Integer] Current retry attempt (0-based)
  # @param log_buffer [LogBuffer] Buffer for logging
  # @return [Boolean] always true (MCP failure was handled)
  def schedule_mcp_retry(session, failed_servers, mcp_retry_count, log_buffer)
    delay = MCP_RETRY_BASE_DELAY * (2**mcp_retry_count)

    log_buffer.add(
      "MCP connection failure — scheduling retry #{mcp_retry_count + 1}/#{MAX_MCP_CONNECTION_RETRIES} " \
      "in #{delay} seconds (servers: #{failed_servers.map { |s| s['name'] }.join(', ')})",
      level: "warning"
    )
    log_buffer.flush

    session.update!(
      running_job_id: nil,
      metadata: (session.metadata || {}).merge(
        "paused_by" => "mcp_retry",
        "mcp_retry_count" => mcp_retry_count + 1,
        "mcp_last_retry_at" => Time.current.iso8601,
        "mcp_failed_servers" => failed_servers
      )
    )
    session.pause! if session.may_pause?

    # Remove the running loader since we're pausing
    remove_running_loader(session)

    # Re-send the original prompt since MCP failures happen before the agent
    # processes it. Fall back to SYSTEM_RECOVERY if prompt is missing.
    require "automated_prompts"
    retry_prompt = session.prompt.presence || AutomatedPrompts::SYSTEM_RECOVERY
    AgentSessionJob.set(wait: delay.seconds).perform_later(
      session.id,
      retry_prompt
    )

    log_buffer.add(
      "[DIAGNOSTIC] Exiting monitoring loop - MCP retry scheduled in #{delay}s",
      level: "debug"
    )

    true
  end

  # Check if Claude CLI is hung after emitting "Prompt is too long" as a regular
  # assistant message (not an API error with isApiErrorMessage: true).
  #
  # In this variant, the process stays alive but idle (0% CPU, sleeping state)
  # after emitting the message. Since the process never exits, the existing
  # ContextLengthRetryService (which runs on exit) never triggers. Without this
  # check, the CleanupOrphanedSessionsJob would eventually catch it after 15
  # minutes of inactivity, but that's too slow and doesn't trigger compact recovery.
  #
  # When detected, we terminate the process and set a metadata flag. On the next
  # monitoring loop iteration, wait_nonblock detects the exit and handle_exit
  # routes to compact recovery via the flag.
  #
  # @param session [Session] The current session
  # @param process_pid [Integer] The Claude CLI process PID
  # @param log_buffer [LogBuffer] Buffer for logging
  # @return [Boolean] true if hang was detected and process terminated
  def check_and_handle_prompt_too_long_hang(session, process_pid, log_buffer)
    transcript_content = session.transcript
    return false unless transcript_content.present?

    lines = transcript_content.lines
    return false if lines.empty?

    # Find the last non-empty line
    last_line = lines.reverse_each.find { |l| l.strip.present? }
    return false unless last_line

    begin
      last_entry = JSON.parse(last_line.strip)
    rescue JSON::ParserError
      return false
    end

    # Must be a regular assistant message (NOT an API error - those exit the process)
    return false unless last_entry["type"] == "assistant"
    return false if last_entry["isApiErrorMessage"] == true

    # Extract message text
    message_content = last_entry.dig("message", "content")
    return false unless message_content.is_a?(Array)

    message_text = message_content
      .select { |block| block.is_a?(Hash) && block["type"] == "text" }
      .map { |block| block["text"] }
      .join(" ")
      .strip

    return false if message_text.blank?

    # Guard against false positives: the actual "Prompt is too long" message from
    # Claude CLI is always a short standalone message, not embedded in a longer response.
    # A legitimate long response that happens to contain error-like phrases should not
    # trigger process termination.
    return false if message_text.length > 200

    # Check if message matches context length error patterns
    return false unless ContextLengthRetryService::CONTEXT_LENGTH_ERROR_PATTERNS.any? { |pattern|
      message_text.match?(pattern)
    }

    # Prevent duplicate detection via line count tracking
    current_line_count = lines.count { |l| l.strip.present? }
    last_detected = session.metadata&.dig("prompt_too_long_hang_detected_at_line")
    return false if last_detected && last_detected >= current_line_count

    # === HANG DETECTED ===
    log_buffer.add(
      "Detected 'Prompt is too long' hang - process #{process_pid} alive but idle. Terminating for compact recovery.",
      level: "warning"
    )
    log_buffer.flush

    with_db_retry do
      session.update!(
        metadata: (session.metadata || {}).merge(
          "prompt_too_long_hang_detected_at_line" => current_line_count,
          "prompt_too_long_hang_detected" => true
        )
      )
    end

    # Terminate the hung process - wait_nonblock will detect the exit on the next iteration
    terminate_process(session, process_pid, session.metadata&.dig("clone_path"), log_buffer)

    true
  rescue => e
    Rails.logger.error "[AgentSessionJob] Error checking for prompt too long hang: #{e.message}"
    false
  end

  # Reset SIGTERM retry counter if process has been running successfully
  # for SIGTERM_RETRY_RESET_THRESHOLD seconds since the last SIGTERM retry.
  #
  # This prevents premature session failures when multiple SIGTERM events occur
  # but are separated by meaningful periods of successful operation. For example,
  # if a session experiences 3 SIGTERMs over several hours, with successful runs
  # between them, we don't want to fail the session on the 4th SIGTERM.
  #
  # @param session [Session] The current session
  # @param last_sigterm_retry_at [Time, nil] When the last SIGTERM retry occurred
  # @param log_buffer [LogBuffer] Buffer for logging
  def check_and_reset_sigterm_retry_counter(session, last_sigterm_retry_at, log_buffer)
    return unless last_sigterm_retry_at
    return unless session.metadata&.dig("sigterm_retry_count")&.positive?

    time_since_last_sigterm = Time.current - last_sigterm_retry_at
    return unless time_since_last_sigterm >= SIGTERM_RETRY_RESET_THRESHOLD

    # Process has been running successfully for the threshold duration - reset counter
    previous_count = session.metadata["sigterm_retry_count"]
    with_db_retry do
      session.update!(
        metadata: session.metadata.except(
          "sigterm_retry_count",
          "sigterm_retry_timestamps",
          "last_sigterm_at"
        )
      )
    end

    log_buffer.add(
      "SIGTERM retry counter reset (was #{previous_count}) - process stable for #{time_since_last_sigterm.round}s",
      level: "info"
    )
  rescue => e
    Rails.logger.error "[AgentSessionJob] Error resetting SIGTERM retry counter: #{e.message}"
  end

  # Reset API error retry counter if process has been running successfully
  # for SIGTERM_RETRY_RESET_THRESHOLD seconds since the last API error retry.
  #
  # Uses the same threshold as SIGTERM retries since the principle is the same:
  # if the process has been stable for a while, allow fresh retries for future errors.
  #
  # @param session [Session] The current session
  # @param last_api_error_retry_at [Time, nil] When the last API error retry occurred
  # @param log_buffer [LogBuffer] Buffer for logging
  def check_and_reset_api_error_retry_counter(session, last_api_error_retry_at, log_buffer)
    return unless last_api_error_retry_at
    return unless session.metadata&.dig("api_error_retry_count")&.positive?

    time_since_last_retry = Time.current - last_api_error_retry_at
    return unless time_since_last_retry >= SIGTERM_RETRY_RESET_THRESHOLD

    previous_count = session.metadata["api_error_retry_count"]
    # Only clear retry count and timestamp — preserve api_error_last_checked_line
    # so the transcript scanner doesn't re-process old errors on the next failure.
    # The scan position tracks which errors have been handled; the retry count
    # tracks how many retries have been attempted. These are independent concerns.
    with_db_retry do
      session.update!(
        metadata: session.metadata.except(
          "api_error_retry_count",
          "last_api_error_retry_at"
        )
      )
    end

    log_buffer.add(
      "API error retry counter reset (was #{previous_count}) - process stable for #{time_since_last_retry.round}s",
      level: "info"
    )
  rescue => e
    Rails.logger.error "[AgentSessionJob] Error resetting API error retry counter: #{e.message}"
  end

  # Terminate a running process
  def terminate_process(session, process_pid, clone_path, log_buffer)
    return unless process_pid

    termination_service = ProcessTerminationService.new(
      process_pid: process_pid,
      process_manager: @process_manager,
      log_buffer: log_buffer,
      session: session
    )
    termination_service.terminate
  end

  # Check if a process is running
  def process_running?(pid)
    return false unless pid
    @process_manager.running?(pid)
  end

  # Remove a consumed interrupt_terminate_pid request from session metadata.
  # Locked read-modify-write so a concurrent metadata write (e.g. the
  # interrupting job recording its own process_pid) isn't clobbered, and pid-
  # guarded so we only clear the exact request we are honoring. Non-fatal: a
  # failure here just leaves a stale flag that Change 4's spawn-time cleanup and
  # the pid scope already render harmless.
  def clear_interrupt_terminate_request(session, process_pid)
    session.with_lock do
      metadata = session.metadata || {}
      flagged = metadata["interrupt_terminate_pid"]
      # Compare numerically: metadata round-trips through JSON and the flag may
      # be stored as an Integer or a String depending on the writer.
      if process_pid && flagged && flagged.to_i == process_pid.to_i
        session.update!(metadata: metadata.except("interrupt_terminate_pid"))
      end
    end
  rescue => e
    Rails.logger.warn "[AgentSessionJob] Failed to clear interrupt_terminate_pid for session #{session&.id}: #{e.message}"
  end

  # Cleanup the clone directory
  def cleanup_clone(session, clone_path, log_buffer)
    return unless clone_path

    GitCloneService.cleanup_clone(clone_path)
    log_buffer.add(
      "Clone cleaned up: #{clone_path}",
      level: "info"
    )
  rescue => e
    log_buffer.add(
      "Error cleaning up clone: #{e.message}",
      level: "error"
    )
  end

  # Start log streaming in a background thread
  def start_log_streaming(session, process_pid, stderr_log_path, working_directory)
    Thread.new do
      # Thread-local log buffer for streaming logs
      thread_log_buffer = LogBuffer.new(session)
      stderr_position = 0
      mcp_log_positions = {}
      iteration = 0

      loop do
        iteration += 1
        # Check if process is still running
        break unless process_running?(process_pid)

        # Stream stderr
        if @file_system.exists?(stderr_log_path)
          File.open(stderr_log_path, "r") do |file|
            file.seek(stderr_position)
            while (line = file.gets)
              next if line.strip.empty?
              thread_log_buffer.add(line.chomp, level: "verbose")
            end
            stderr_position = file.pos
          end
        end

        # Stream MCP cache logs
        stream_mcp_cache_logs(session, working_directory, mcp_log_positions, thread_log_buffer)

        # Flush every 5 iterations (2.5 seconds)
        if (iteration % 5).zero?
          thread_log_buffer.flush
        end

        # Sleep briefly before next check
        sleep 0.5
      end

      # Read any remaining logs after process exits
      if @file_system.exists?(stderr_log_path)
        File.open(stderr_log_path, "r") do |file|
          file.seek(stderr_position)
          while (line = file.gets)
            next if line.strip.empty?
            thread_log_buffer.add(line.chomp, level: "verbose")
          end
        end
      end

      # Read any remaining MCP logs
      stream_mcp_cache_logs(session, working_directory, mcp_log_positions, thread_log_buffer)

      # Final flush
      thread_log_buffer.flush

    rescue => e
      thread_log_buffer&.add(
        "Error in log streaming thread: #{e.message}",
        level: "error"
      )
      thread_log_buffer&.flush
    end
  end

  # Stream MCP cache logs to database
  # MCP logs are in JSONL format (one JSON object per line)
  def stream_mcp_cache_logs(session, working_directory, mcp_log_positions, log_buffer)
    cache_dir = cache_directory_path(working_directory)
    return unless cache_dir && @file_system.exists?(cache_dir)

    # Find all MCP log directories
    mcp_log_dirs = @file_system.glob(File.join(cache_dir, "mcp-logs-*"))

    mcp_log_dirs.each do |log_dir|
      server_name = File.basename(log_dir).sub(/^mcp-logs-/, "")

      # Find all .jsonl log files (JSONL format)
      log_files = @file_system.glob(File.join(log_dir, "*.jsonl"))

      log_files.each do |log_file|
        # Initialize line count for this file
        mcp_log_positions[log_file] ||= 0
        processed_lines = mcp_log_positions[log_file]

        # Read entire file and parse as JSONL (one JSON object per line)
        if @file_system.exists?(log_file)
          content = @file_system.read(log_file)
          next if content.strip.empty?

          lines = content.lines
          current_line_count = 0

          lines.each do |line|
            current_line_count += 1
            # Skip already processed lines
            next if current_line_count <= processed_lines

            line = line.strip
            next if line.empty?

            begin
              entry = JSON.parse(line)

              message = nil
              if entry["error"]
                message = "[MCP:#{server_name}] ERROR: #{entry['error']}"
              elsif entry["debug"]
                message = "[MCP:#{server_name}] #{entry['debug']}"
              end

              if message
                log_buffer.add(message, level: "verbose")
              end
            rescue JSON::ParserError
              # Skip malformed lines silently
            end
          end

          # Update processed line count
          mcp_log_positions[log_file] = current_line_count
        end
      end
    end
  rescue => e
    log_buffer.add(
      "Error streaming MCP cache logs: #{e.message}",
      level: "error"
    )
  end

  # Calculate cache directory path for MCP logs.
  # Applies the same working_directory sanitization as the resume transcript path,
  # but rooted at the Claude CLI cache base (PathSanitizer.cache_base) where MCP
  # server logs live — distinct from the transcript directory under ~/.claude/projects.
  def cache_directory_path(working_directory)
    return nil unless working_directory

    sanitized_path = PathSanitizer.sanitize(working_directory)
    File.join(PathSanitizer.cache_base, sanitized_path)
  end

  # Build prompt with goal suffix if configured
  # @param base_prompt [String] The base prompt to augment
  # @param session [Session] The session with potential goal
  # @return [String] The prompt with goal appended (if configured)
  def build_prompt_with_goal(base_prompt, session)
    # A blank base prompt carries no task, so return it as-is rather than appending
    # goal/notes. This keeps two invariants the initial-spawn guard relies on:
    #   1. prompt_with_goal stays blank when session.prompt is blank, so the guard
    #      catches a task-less spawn instead of launching an agent on a bare goal
    #      string (a goal/session_notes alone would otherwise make it non-blank).
    #   2. We never reach `nil + String` below, which would raise NoMethodError and
    #      bubble to ActiveJob as a terminal, alerting failure.
    return base_prompt if base_prompt.blank?

    prompt = base_prompt

    if session.goal.present?
      # Resolve goal ID to its description if it matches a known goal,
      # otherwise treat it as free-text and pass through as-is
      resolved_goal = GoalsConfig.find(session.goal)&.description || session.goal

      # Append goal instruction to the prompt
      goal_suffix = "\n\nThe user has indicated the goal for this task is: #{resolved_goal}.\n\nHand back control to the user AS SOON as the goal is satisfied. Do not continue past it, do not stop iterating on your progress until you have achieved it."
      prompt += goal_suffix
    end

    if session.session_notes.present?
      current_time = Time.current.iso8601
      last_edited = session.session_notes_updated_at&.iso8601 || current_time
      prompt += "\n\n<session-notes> <info>These session notes are not necessarily instructions; just notes the user left for themself that might be helpful in understanding exactly what's going on. Last edited #{last_edited} (current time: #{current_time})</info> #{session.session_notes} </session-notes>"
    end

    prompt
  end

  # Append a clearly-delimited note describing user-attached files so the agent
  # knows the files exist, where they live on disk, and how to handle large ones.
  # Files are passed as an array of hashes with :path, :original_filename, :size keys.
  def append_file_attachment_note(prompt, files)
    list_lines = files.map do |f|
      path = f[:path] || f["path"]
      name = f[:original_filename] || f["original_filename"]
      size = f[:size] || f["size"]
      size_str = size ? " (#{format_attachment_size(size.to_i)})" : ""
      "- #{path} — original filename: #{sanitize_filename_for_prompt(name)}#{size_str}"
    end

    note = <<~NOTE.strip


      <attached-files>
      The user has attached the following file(s) to this message:
      #{list_lines.join("\n")}

      Read the relevant file(s) to address the request. For large files (>~100KB), prefer reading in chunks (Read with offset/limit), grepping for specific patterns, or using head/tail rather than reading the entire file at once, to avoid filling the context window.
      </attached-files>
    NOTE

    "#{prompt}\n\n#{note}"
  end

  # Strip characters from a user-supplied filename that could break out of the
  # surrounding <attached-files> block and inject prompt instructions, since
  # the agent treats angle-bracket tags structurally.
  def sanitize_filename_for_prompt(name)
    name.to_s.gsub(/[<>\r\n]/, "_")
  end

  def format_attachment_size(bytes)
    return "#{bytes} B" if bytes < 1024
    return "#{(bytes / 1024.0).round(1)} KB" if bytes < 1024 * 1024
    "#{(bytes / (1024.0 * 1024.0)).round(1)} MB"
  end

  # Inject secrets from Rails credentials into a .env file in the working directory
  # @param working_directory [String] The directory to write the .env file to
  # @param log_buffer [LogBuffer] Buffer for logging
  def inject_secrets_to_env_file(working_directory, log_buffer)
    secrets = SecretsLoader.all
    return if secrets.empty?

    env_file_path = File.join(working_directory, ".env")

    # Format secrets as KEY="value" with proper escaping for special characters
    # Double quotes allow the .env parser to handle values containing equals signs,
    # newlines, and other special characters. Inner double quotes are escaped.
    env_content = secrets.map do |key, value|
      escaped_value = value.to_s.gsub("\\", "\\\\\\\\").gsub('"', '\\"').gsub("\n", "\\n")
      "#{key}=\"#{escaped_value}\""
    end.join("\n")
    env_content += "\n" # Ensure trailing newline

    @file_system.write(env_file_path, env_content)

    # Set restrictive permissions (owner read/write only) for security
    @file_system.chmod(0o600, env_file_path)

    log_buffer.add(
      "Injected #{secrets.size} secret(s) into .env file",
      level: "info"
    )
  rescue => e
    log_buffer.add(
      "Warning: Failed to inject secrets to .env file: #{e.class} - #{e.message}",
      level: "warning"
    )
  end

  # Persist auto-injected MCP server names in session custom_metadata so the UI
  # can display them alongside the explicitly configured servers.
  def store_injected_mcp_servers(session, injected_servers)
    return if injected_servers.blank?

    merged = (session.custom_metadata || {}).merge("injected_mcp_servers" => injected_servers)
    session.update!(custom_metadata: merged)
  end

  # Check OAuth requirements for MCP servers and inject credentials if available.
  #
  # For remote MCP servers (http, streamable-http, sse types), this method:
  # 1. Checks if OAuth credentials exist in the database
  # 2. For servers without credentials, probes to see if OAuth is required
  # 3. If any server requires OAuth but lacks credentials, returns blocked: true
  # 4. If all credentials are available, injects them into the working directory
  #
  # @param session [Session] The session with MCP servers configured
  # @param working_directory [String] The directory to write credentials to
  # @param log_buffer [LogBuffer] Buffer for logging
  # @return [Hash] { blocked: Boolean, missing_servers: Array<Hash> }
  def check_and_inject_oauth_credentials(session, working_directory, log_buffer)
    result = { blocked: false, missing_servers: [] }

    return result if oauth_mcp_servers(session).blank?

    # Create injector to check credentials status
    injector = McpOauthCredentialInjector.new(session, working_directory: working_directory)
    status = injector.check_credentials_status

    # Skip if no remote servers that might need OAuth
    return result if status.empty?

    # Check each remote server for OAuth requirements
    oauth_service = McpOauthService.new
    servers_needing_oauth = []

    status.each do |server_name, server_status|
      next if server_status[:has_credential] && server_status[:credential_valid]

      # Server doesn't have credentials - check if OAuth is required
      server_url = server_status[:server_url]
      next unless server_url.present?

      log_buffer.add(
        "Checking OAuth requirement for MCP server: #{server_name}",
        level: "info"
      )

      # If credential exists but refresh failed, we know OAuth is required — the server
      # previously had valid credentials that have since expired and can't be renewed.
      # Skip probing and immediately require re-auth to avoid Claude Code's slow 60s
      # retry loop discovering the 401 on its own.
      if server_status[:refresh_failed] || server_status[:requires_reauth]
        log_buffer.add(
          "MCP server '#{server_name}' requires OAuth re-authorization (token refresh unavailable)",
          level: "warning"
        )
        entry = {
          server_name: server_name,
          server_url: server_url,
          credential_key: server_status[:credential_key]
        }
        # Include pre-registered OAuth config if available so the re-auth flow
        # can use the client_id, authorization URL, etc.
        if server_status[:has_preregistered_oauth]
          entry[:preregistered_oauth] = server_status[:preregistered_oauth_config]
        end
        servers_needing_oauth << entry
        next
      end

      # If pre-registered OAuth config exists in Rails credentials, OAuth is required
      # This takes precedence over server probing because some servers (like BigQuery)
      # don't require auth for initialization but do for tool calls
      if server_status[:has_preregistered_oauth]
        log_buffer.add(
          "MCP server '#{server_name}' requires OAuth authorization (pre-registered in credentials)",
          level: "warning"
        )
        servers_needing_oauth << {
          server_name: server_name,
          server_url: server_url,
          credential_key: server_status[:credential_key],
          preregistered_oauth: server_status[:preregistered_oauth_config]
        }
        next
      end

      # Otherwise, probe the server to see if OAuth is required
      begin
        requirement = oauth_service.check_oauth_requirement(server_url)

        if requirement.required
          log_buffer.add(
            "MCP server '#{server_name}' requires OAuth authorization",
            level: "warning"
          )
          servers_needing_oauth << {
            server_name: server_name,
            server_url: server_url,
            credential_key: server_status[:credential_key],
            oauth_metadata: requirement.metadata
          }
        else
          log_buffer.add(
            "MCP server '#{server_name}' does not require OAuth",
            level: "info"
          )
        end
      rescue => e
        log_buffer.add(
          "Warning: Failed to check OAuth for '#{server_name}': #{e.message}",
          level: "warning"
        )
        # Don't block on probe failures - the server might not be OAuth-protected
      end
    end

    if servers_needing_oauth.any?
      result[:blocked] = true
      result[:missing_servers] = servers_needing_oauth
      return result
    end

    # All credentials available - inject them
    begin
      credentials_path = injector.inject_credentials!
      if credentials_path
        log_buffer.add(
          "Injected OAuth credentials to: #{credentials_path}",
          level: "info"
        )
      end
    rescue => e
      log_buffer.add(
        "Warning: Failed to inject OAuth credentials: #{e.message}",
        level: "warning"
      )
      # Don't block if injection fails - Claude might not need the credentials
    end

    result
  end

  def oauth_mcp_servers(session)
    session.user_selected_mcp_servers
  end

  # Re-injects MCP OAuth credentials into the runtime credential store and gates
  # the spawn when a required credential is still missing or unrefreshable.
  #
  # This runs before every spawn path that may launch the CLI — fresh clone,
  # follow-up prompt, and reused clone (post-OAuth retry / job retry). The
  # freshly-authorized DB credential is the source of truth; re-injecting on
  # every path guarantees it reaches the shared on-disk credential store before
  # the CLI reads it, rather than letting the CLI pick up a stale token from a
  # prior session and fail with invalid_grant/401.
  #
  # @return [Boolean] true when the session was blocked (transitioned to failed
  #   with failure_reason "oauth_required") — the caller MUST return from
  #   #perform. false when there is nothing to gate or credentials were injected
  #   successfully and the spawn may proceed.
  def gate_and_inject_oauth!(session, working_directory, log_buffer, blocked_message:)
    return false if oauth_mcp_servers(session).blank?

    oauth_result = check_and_inject_oauth_credentials(session, working_directory, log_buffer)
    return false unless oauth_result[:blocked]

    log_buffer.add(blocked_message, level: "warning")
    log_buffer.flush
    session.update!(
      running_job_id: nil,
      metadata: (session.metadata || {}).merge(
        "failure_reason" => "oauth_required",
        "oauth_required_servers" => oauth_result[:missing_servers]
      )
    )
    session.fail! if session.may_fail?
    true
  end
end
