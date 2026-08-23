# frozen_string_literal: true

module Sessions
  # Stop a running session's turn NOW and leave it dormant in `waiting`.
  #
  # == Why this exists
  #
  # "Pause Until" arms a wake and expects the session to go to sleep. On a
  # `needs_input` session that is one step — Trigger's after_create callback
  # calls `sleep!` and the session is dormant before the request finishes. On a
  # RUNNING session the same callback could only set `pending_sleep`, a note the
  # pause callback reads whenever the current turn happens to end. An agent turn
  # runs for minutes or hours, so from the operator's chair the control did
  # nothing at all: the session kept running, the badge never changed, and the
  # only evidence anything had happened was a trigger row they could not see.
  #
  # A human pausing someone else's running session means stop. So the deferral
  # is replaced by the thing the "Pause" button already does — terminate the CLI
  # process — and the session lands in `waiting` in the same gesture.
  #
  # == What it costs
  #
  # The same cost SpotSessionPause pays, and for the same reason it is worth
  # paying: whatever the agent wrote to disk stays written, the tool call in
  # flight is lost, and so is any reasoning not yet flushed to the transcript.
  # That is what "halt continuation" means, and the panel says so before the
  # click rather than after it.
  #
  # == Order of operations
  #
  # The process is terminated BEFORE the status flips, for the reason
  # SessionsController#pause gives: flipping first makes AgentSessionJob's
  # monitoring loop exit on the status change without a final transcript poll,
  # losing the agent's last message. Killing first means the job sees the exit,
  # polls, and stops.
  #
  # Callers arm the wake BEFORE calling this, never after. Arming first means a
  # rejected wake time (a past date, a malformed zone) costs nothing — no turn
  # has been taken away yet — and it means a halt that only partly succeeds
  # degrades to the old deferred behaviour rather than to a session dozing with
  # nothing armed: `pending_sleep` is already written, so the turn's own end
  # still puts the session to sleep.
  #
  # == Why it does not write `paused_by`
  #
  # SessionsController#pause writes `paused_by: "user"`, and that marker means
  # "a human has taken this session over" — Trigger#reusable_session? refuses to
  # deliver into a session carrying it. Writing it here would arm a wake and
  # then guarantee it was dropped on arrival. A Pause Until is the opposite of
  # taking a session over: it says come back at this time, by yourself.
  class HaltRunningTurn
    # @!attribute [r] halted
    #   @return [Boolean] whether the turn was actually stopped
    # @!attribute [r] reason
    #   @return [Symbol] :halted, :not_running, or :could_not_pause
    Result = Data.define(:halted, :reason)

    # @param session [Session]
    # @param reason [Symbol] passed through to ProcessLifecycleManager#terminate
    #   for the log line
    # @return [Result]
    def self.call(session:, reason: :pause_until)
      new(session: session, reason: reason).call
    end

    def initialize(session:, reason: :pause_until)
      @session = session
      @reason = reason
    end

    attr_reader :session, :reason

    def call
      return Result.new(halted: false, reason: :not_running) unless session.running?

      terminate_process

      return Result.new(halted: false, reason: :could_not_pause) unless pause!

      session.reload
      session.logs.create!(level: "info", content: halted_message)
      # Belt and braces. `pending_sleep` is what normally carries the session
      # needs_input -> waiting, via the pause callback's execute_pending_sleep —
      # which swallows its own failures (it alerts rather than raises). A session
      # left in needs_input would sit in the operator's action queue asking for a
      # decision they already made.
      session.sleep! if session.needs_input? && session.may_sleep?

      Result.new(halted: true, reason: :halted)
    end

    private

    # @return [Boolean] whether the session was transitioned out of `running`
    def pause!
      paused = false

      ActiveRecord::Base.transaction do
        session.lock!
        # Re-read under the lock rather than trusting the check at the top: the
        # terminate above spends seconds waiting out SIGTERM grace, and the turn
        # may have ended on its own in that window — in which case the session is
        # already needs_input (or already asleep on the pending_sleep the caller
        # armed) and there is nothing left to pause.
        raise ActiveRecord::Rollback unless session.running? && session.may_pause?

        # Written here rather than trusted from the caller, the way
        # SpotSessionPause writes its own. `pending_sleep` is what the pause
        # callback reads to carry the session needs_input -> waiting, and callers
        # get it as a side effect of arming a wake — a side effect whose own
        # writer swallows its failures. Re-asserting it under the lock makes the
        # contract self-enforcing: without it a lost write sends the session
        # through a fully observable `needs_input`, firing the ao_event watchers
        # and the queue drain on the way to a sleep it was always going to reach.
        session.merge_metadata!({ "pending_sleep" => true })

        # The job no longer owns a process; leaving the id set makes the session
        # look owned to the orphan sweep. `pause!`'s own cleanup_running_job does
        # this too, but it runs inside the transition and this is the row we hold.
        session.update_column(:running_job_id, nil)
        session.pause!
        paused = true
      end

      paused
    rescue StandardError => e
      Rails.logger.error(
        "[Sessions::HaltRunningTurn] Could not pause session #{session.id}: #{e.class}: #{e.message}"
      )
      false
    end

    # What the session's own timeline calls this. A halt reached from the MCP
    # tool is not "Pause Until" — that is a web-UI control its caller never
    # touched — so the line is worded off the reason rather than hardcoded.
    def log_prefix
      reason == :pause_into_spot_queue ? "[Spot Queue]" : "[Pause Until]"
    end

    # Written after the pause lands, and unconditionally: a session whose process
    # had already gone gets no line from #terminate_process, and would otherwise
    # have nothing on its timeline saying why its turn stopped.
    def halted_message
      "#{log_prefix} A human stopped this turn and put the session to sleep " \
        "(now #{session.status}). Work already written to disk survives; the tool call in flight does not."
    end

    # Kill the CLI process the session owns. Best effort: a session whose process
    # has already gone still gets paused, which is the state we are trying to
    # reach.
    def terminate_process
      pid = session.metadata&.dig("process_pid")
      return if pid.blank?

      session.logs.create!(level: "info", content: "#{log_prefix} Terminating process #{pid}")

      manager = ProcessLifecycleManager.new(session: session, process_manager: SystemProcessManager.new)
      result = manager.resume_monitoring(pid: pid, stderr_log_path: session.stderr_log_path)
      return unless result.success?

      manager.terminate(reason: reason)
    rescue StandardError => e
      Rails.logger.warn(
        "[Sessions::HaltRunningTurn] Could not terminate the process of session #{session.id}: " \
        "#{e.class}: #{e.message}"
      )
    end
  end
end
