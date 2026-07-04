module Sessions
  Result = Struct.new(:success, :error, :error_code, keyword_init: true) do
    def success?
      success
    end
  end

  # Single source of truth for "send this enqueued message NOW, interrupting the
  # currently running turn if needed". Both the web controller
  # (EnqueuedMessagesController#interrupt) and the v1 API controller
  # (Api::V1::EnqueuedMessagesController#interrupt) delegate here so the two
  # paths cannot diverge.
  #
  # Race-free contract
  # ------------------
  # The pre-existing implementation was vulnerable to a duplicate-delivery /
  # dropped-message race when two interrupt requests arrived in rapid
  # succession on the same session. Each request would independently:
  #   1. read state, 2. terminate the process, 3. destroy the EnqueuedMessage,
  #   4. enqueue a fresh AgentSessionJob with the message *content* as a
  #      positional argument.
  # Because the row was destroyed before the job picked it up, the queue stopped
  # being the source of truth — once two interrupts crossed paths, one message
  # would be lost or re-delivered.
  #
  # This service makes that race architecturally impossible:
  #
  #   * A per-session Postgres advisory lock (Session.with_session_lock) wraps
  #     the entire interrupt operation — state validation, process termination,
  #     message reorder, and dispatch. Two concurrent interrupt requests on the
  #     same session serialize at the database level; different sessions
  #     proceed in parallel.
  #   * The EnqueuedMessage row is the single durable queue. We do NOT
  #     destroy it in the controller and pass content via job args. Instead
  #     we reorder the target message to position 1 and let
  #     EnqueuedMessageProcessorService claim it via FOR UPDATE SKIP LOCKED.
  #     The row is destroyed only after the claim succeeds inside the
  #     processor service's transaction.
  #   * The processor service marks the message status as "processing" before
  #     destruction, giving us an exactly-once delivery boundary that survives
  #     job retries.
  #
  # Together these guarantees mean: every EnqueuedMessage reaches the agent
  # exactly once, in FIFO order, even under concurrent interrupt traffic.
  #
  # The advisory lock is held across process termination (SIGTERM + reap),
  # which can take a few seconds. This is a deliberate trade — concurrent
  # interrupts on the same session are rare and correctness is worth the
  # short blocking window. Different sessions are unaffected.
  class InterruptService
    # @param session [Session]
    # @param enqueued_message [EnqueuedMessage] must belong to session
    # @param actor [String] free-form string recorded for observability
    #   (e.g. "web", "api_v1") — appears in logs.
    # @param process_lifecycle_manager [ProcessLifecycleManager, nil] inject
    #   for tests; defaults to a real one bound to session.
    # @param processor_service [EnqueuedMessageProcessorService, nil] inject
    #   for tests; defaults to a real one bound to session.
    def initialize(session:, enqueued_message:, actor: "web",
                   process_lifecycle_manager: nil,
                   processor_service: nil)
      @session = session
      @enqueued_message = enqueued_message
      @actor = actor
      @process_lifecycle_manager = process_lifecycle_manager
      @processor_service = processor_service
    end

    def call
      # Cheap pre-check before taking the lock so obvious garbage requests
      # don't block other interrupts. Belonging is re-checked inside the lock
      # against fresh state (in case the in-memory handles are stale).
      unless @enqueued_message.session_id == @session.id
        return Result.new(success: false, error: "Message does not belong to session", error_code: :not_found)
      end

      @session.reload
      unless @session.running? || @session.waiting? || @session.needs_input?
        return Result.new(
          success: false,
          error: "Cannot interrupt when session is #{@session.status}. Session must be running, waiting, or needs_input.",
          error_code: :unprocessable_entity
        )
      end

      Session.with_session_lock(@session.id) do
        # Re-read state with the lock held — a concurrent interrupt may have
        # transitioned the session in the window between the cheap check
        # above and the lock acquisition.
        @session.reload
        @enqueued_message.reload

        unless @enqueued_message.persisted?
          return Result.new(success: false, error: "Message no longer exists", error_code: :not_found)
        end

        unless @enqueued_message.session_id == @session.id
          return Result.new(success: false, error: "Message does not belong to session", error_code: :not_found)
        end

        unless @enqueued_message.status == "pending"
          return Result.new(
            success: false,
            error: "Message is already being delivered (status: #{@enqueued_message.status})",
            error_code: :conflict
          )
        end

        unless @session.running? || @session.waiting? || @session.needs_input?
          return Result.new(
            success: false,
            error: "Cannot interrupt when session is #{@session.status}. Session must be running, waiting, or needs_input.",
            error_code: :unprocessable_entity
          )
        end

        # Pause + terminate the running turn (if any). Held inside the lock so
        # a concurrent interrupt can't transition the session back to running
        # between our terminate and our dispatch. Idempotent — safe to re-run.
        if @session.running?
          terminate_running_process
          @session.reload
        end

        # Move the target message to the front of the queue. If a concurrent
        # interrupt previously promoted a different message to position 1
        # (and held the lock long enough to dispatch it), that previous target
        # has already been destroyed via the processor service's claim — so
        # reorder_to(1) here doesn't displace anything live; it just slots us
        # ahead of whatever pending peers remain.
        # Net behavior: when two interrupts arrive on the same session, both
        # messages are delivered, with the later-acquiring-lock one going
        # first (which matches the user's "interrupt with this message NOW"
        # intent).
        if @enqueued_message.position != 1
          @enqueued_message.reorder_to(1)
        end

        # Drain the queue: claims the front message (which we just promoted)
        # via FOR UPDATE SKIP LOCKED, marks status=processing, transitions
        # session to running, and enqueues the next AgentSessionJob with the
        # message content + attachments. The row is destroyed only after the
        # claim succeeds inside the processor's transaction.
        # If the claim fails here, it means a peer claimed our message under
        # SKIP LOCKED before we got there — surface as a 409 conflict, not a
        # 500, since the system is functioning correctly and the caller's
        # request is simply stale.
        unless processor_service.process_next_message
          return Result.new(
            success: false,
            error: "Message could not be claimed — likely already dispatched by a concurrent interrupt",
            error_code: :conflict
          )
        end
      end

      truncated = @enqueued_message.content.to_s
      truncated = "#{truncated[0..197]}..." if truncated.length > 200
      with_db_retry_safe do
        @session.logs.create!(
          content: "Enqueued message sent as interrupt via #{@actor}: #{truncated}",
          level: "info"
        )
      end

      Result.new(success: true)
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.warn "[Sessions::InterruptService] Record not found: #{e.message}"
      Result.new(success: false, error: "Message no longer exists", error_code: :not_found)
    rescue => e
      # Log the full exception details server-side for debugging, but don't
      # leak raw exception messages (which may contain SQL fragments, file
      # paths, or other internals) to API consumers.
      Rails.logger.error(
        "[Sessions::InterruptService] Failed to interrupt session #{@session.id}: " \
        "#{e.class}: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}"
      )
      with_db_retry_safe do
        @session.logs.create!(
          content: "Failed to send interrupt via #{@actor}: #{e.message}",
          level: "error"
        )
      end
      Result.new(
        success: false,
        error: "Internal error while dispatching interrupt",
        error_code: :internal_server_error
      )
    end

    private

    def processor_service
      @processor_service ||= EnqueuedMessageProcessorService.new(@session)
    end

    def lifecycle_manager
      @process_lifecycle_manager ||= ProcessLifecycleManager.new(
        session: @session,
        process_manager: SystemProcessManager.new
      )
    end

    # Pause the session via the state machine and SIGTERM the Claude CLI
    # process. Runs inside the per-session advisory lock — concurrent
    # interrupts on the same session never reach here simultaneously.
    # Idempotent: if the process is already gone we just transition state.
    def terminate_running_process
      process_pid = @session.metadata&.dig("process_pid")

      with_db_retry_safe do
        if process_pid
          @session.logs.create!(
            content: "Pausing running session for interrupt via #{@actor} (terminating PID #{process_pid})",
            level: "info"
          )
        end
        @session.pause! if @session.may_pause?
      end

      return unless process_pid

      stderr_log_path = File.join(@session.metadata&.dig("clone_path") || "", "claude_stderr.log")
      resume_result = lifecycle_manager.resume_monitoring(
        pid: process_pid,
        stderr_log_path: stderr_log_path
      )

      if resume_result.success?
        # Same PID namespace as the Claude CLI process (development /
        # single-container): we can signal it directly. terminate escalates
        # SIGTERM -> SIGKILL within a bounded window and reaps the child.
        lifecycle_manager.terminate(reason: :interrupt)
      else
        # We cannot see the process from here. resume_monitoring reports failure
        # both when the process is genuinely gone AND when it is merely invisible
        # to this process — which is the *normal* case in production, where the
        # Claude CLI runs in the worker container's PID namespace while this code
        # runs in the web container. A web-side Process.kill can never reach it.
        #
        # Record a durable, pid-scoped termination request that the worker's own
        # monitoring loop honors on its next iteration. The worker is the only
        # actor that can actually signal the process. Scoping the request to the
        # exact pid guarantees the freshly-resumed turn (a different pid) is
        # never affected, and a stale request can never kill a future turn.
        request_worker_side_termination(process_pid)
      end
    end

    # Persist a pid-scoped "terminate this turn" request into session metadata.
    # AgentSessionJob's monitoring loop compares this against its own live
    # process pid every iteration and, on a match, terminates the process and
    # exits — the cross-container-safe way to end an interrupted turn.
    #
    # This flag is a best-effort FAST PATH, not the correctness guarantee.
    # session.metadata is a read-modify-write JSON blob and the still-running
    # worker writes it too (retry timestamps, exit status) without coordinating
    # on this service's advisory lock, so the flag can in principle be clobbered
    # before the worker reads it. The guarantee that a superseded turn is never
    # orphaned lives in the worker loop's running_job_id ownership backstop
    # (AgentSessionJob branch 1c): once the interrupting job reclaims
    # running_job_id, the old turn terminates itself regardless of whether this
    # flag survived. An explicit row lock here would give a false sense of
    # atomicity — the concurrent worker writes don't take it — so we don't bother
    # with one; the whole interrupt already runs under Session.with_session_lock.
    # Logged at info because in production this fires on every cross-container
    # interrupt and self-resolves within one worker loop iteration; it is not an
    # alertable condition.
    def request_worker_side_termination(process_pid)
      with_db_retry_safe do
        @session.update!(metadata: (@session.metadata || {}).merge("interrupt_terminate_pid" => process_pid))
        @session.logs.create!(
          content: "Interrupt could not terminate PID #{process_pid} from the web process " \
            "(separate container/PID namespace); handed termination to the session worker",
          level: "info"
        )
      end
    end

    # Wrap log writes so a logging failure can't take down the interrupt
    # operation itself. We still escalate the underlying error via the rescue
    # in #call.
    def with_db_retry_safe
      yield
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn "[Sessions::InterruptService] DB write failed (non-fatal): #{e.message}"
      nil
    end
  end
end
