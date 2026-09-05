# frozen_string_literal: true

module Sessions
  # A turn raised before the agent process was ever spawned, so the prompt it was
  # carrying was never delivered. Come to rest in the human's action queue instead
  # of in `failed`.
  #
  # ## The bug this closes (#439)
  #
  # Production session 3949 had finished a turn, been archived, and was unarchived
  # to receive a follow-up carrying a live user request. The unarchive rebuilt the
  # clone, `air prepare` died with `ENOENT` on the agent root's `.mcp.json` (the
  # mass-deletion patch replay of #411, fixed separately in #413), and #perform's
  # catch-all stamped `failure_reason: "exception"` and called `fail!`.
  #
  # That is where the request stopped being recoverable. `failed` is not in the
  # `needs_input` action queue the homepage presents as the user's to-do list, the
  # session that had delegated the work archived itself seventy seconds after
  # handing off, and nothing in Zimmer restarts a session that failed for any
  # reason other than `GoodJob::InterruptError`. The prompt sat dropped for two
  # days and was found by a human sweeping unarchived sessions.
  #
  # The failure was never the problem — the invisibility was. So this does not try
  # to make the turn succeed. It puts the session where somebody looks, and keeps
  # the prompt.
  #
  # ## Why parking and not retrying
  #
  # #400 documents that unarchive plus follow-up can already run two agent
  # processes against one session, so a reflex "re-run the turn that failed" is the
  # wrong shape here: the failures that reach this path are mostly deterministic
  # (an ENOENT on a clone that is wrong stays wrong), and a retry that races the
  # first process buys a double-run in exchange for nothing. Parking is the whole
  # recovery, and the human whose request it was is the one who decides whether to
  # send it again.
  #
  # ## The four conditions, and why each one is load-bearing
  #
  # 1. **Nothing was spawned.** The caller answers this from
  #    `ProcessLifecycleManager#current_pid` and its own local pid, so the question
  #    is "did THIS job start an agent", not "is there an agent somewhere". A turn
  #    that died after its process existed is a runtime fault with a transcript to
  #    read; it keeps the `failed` path untouched.
  # 2. **The turn carried a prompt.** An undelivered prompt is what makes this a
  #    person's problem rather than a machine's. A promptless turn dying at boot
  #    has nothing a human is waiting on.
  # 3. **The session is `running`.** `pause` transitions from `running` only, and
  #    `running` is exactly the state a delivered follow-up is in — every path that
  #    hands a prompt to a job resumes first. A session still `waiting` is having
  #    its FIRST turn set up, which is a different case: nobody has been told the
  #    work started, and its failure is in front of the person who just created it.
  # 4. **Not a status-summary fork.** Zimmer's own bookkeeping, which must never
  #    take a slot in the action queue or page anyone — the same carve-out
  #    `SessionStateMachine`'s `pause` callback makes.
  #
  # ## What the park deliberately does not write
  #
  # No `paused_by: "recovery"`. That marker is a promise that a sweep will continue
  # the session, and `CleanupOrphanedSessionsJob` and `DeploymentRecoveryJob` both
  # honour it. Handing them a session whose boot is deterministically broken buys a
  # loop of doomed auto-continues and the same silence at the end of it. Without the
  # marker no sweep touches the row, `announcement_deferred_to_recovery_sweep?` is
  # false, and the `pause` callback makes the announcement itself — the settled
  # `session_needs_input` wake fan-out and the debounced push. That announcement is
  # the half of this fix that reaches a human who is not looking at the homepage.
  #
  # `Sessions::RestartUnstartedTurn`'s abandon path parks the same way for the same
  # reason, and the two are siblings: that one is "the process is gone and wrote
  # nothing", this one is "the process never existed".
  class ParkUndeliveredTurn
    # Recorded in `failure_reason` so every surface that reads it — the session
    # page's failure block, `Session#failure_summary`, the health rollups — can
    # tell this park from an ordinary `pause`.
    FAILURE_REASON = "undelivered_turn"

    # @param session [Session]
    # @param error [Exception] the exception #perform's catch-all caught
    # @param prompt [String, nil] the prompt this turn was carrying
    # @param spawned [Boolean] whether this job started an agent process
    # @param log_buffer [LogBuffer, nil] the caller's buffer, so the disposition
    #   lands on the session's own timeline next to the error it explains
    # @return [Boolean] true when the session was parked and the caller must not
    #   also fail it
    def self.call(session, **kwargs)
      new(session, **kwargs).call
    end

    def initialize(session, error:, prompt:, spawned:, log_buffer: nil)
      @session = session
      @error = error
      @prompt = prompt
      @spawned = spawned
      @log_buffer = log_buffer
    end

    def call
      return false if @spawned
      return false if @prompt.blank?

      # Re-read the row before deciding from it. The setup this rescue sits at the
      # end of runs for minutes, and the session object the job has carried since
      # before the clone is not evidence of what the row says now.
      session.reload
      return false unless session.running?
      return false if session.status_summary_fork?

      # update_columns, as the loud path does: the original exception may well have
      # been a validation failure (a stale MCP server catalog is the observed one),
      # and `update!` would re-raise it here and strand the session `running` with
      # nobody driving it.
      session.update_columns(
        running_job_id: nil,
        metadata: (session.metadata || {}).merge(
          "failure_reason" => FAILURE_REASON,
          "exception_class" => @error.class.name,
          "exception_message" => @error.message.to_s.truncate(AgentSessionJob::EXCEPTION_MESSAGE_MAX_CHARS),
          # Put the prompt back where every recovery path looks for it. The
          # follow-up arm of #perform consumes `pending_follow_up_prompt` on the way
          # in — long before the setup that just raised — so after a boot failure the
          # only surviving copy of the user's raw text is this job's arguments, which
          # die with the job. `active_follow_up_prompt` is not a substitute: it holds
          # the goal-wrapped expansion, and replaying that would deliver the goal
          # block twice (Sessions::RestartUnstartedTurn#prompt says the same).
          "pending_follow_up_prompt" => @prompt
        )
      )
      session.reload

      add_log(
        "This turn stopped before the agent started, so the prompt it was carrying was never delivered " \
        "(#{@error.class.name}). Nothing ran and nothing is retried — the session is coming to rest in the " \
        "action queue rather than failing where nobody looks, and the prompt is kept so continuing the " \
        "session re-sends it.",
        level: "warning"
      )
      session.pause! if session.may_pause?

      Rails.logger.warn(
        "[Sessions::ParkUndeliveredTurn] Session #{session.id} parked in needs_input: its turn raised " \
        "#{@error.class.name} before the agent started, and the prompt was never delivered"
      )
      true
    rescue => e
      # A park that cannot run must not become the thing that breaks the failure
      # path. Answer false, and the caller's `fail!` runs exactly as it used to.
      Rails.logger.error(
        "[Sessions::ParkUndeliveredTurn] Could not park session #{@session&.id}: #{e.class}: #{e.message}"
      )
      false
    end

    private

    attr_reader :session

    def add_log(content, level:)
      @log_buffer&.add(content, level: level)
      @log_buffer&.flush
    rescue => e
      Rails.logger.warn("[Sessions::ParkUndeliveredTurn] Could not log the park: #{e.message}")
    end
  end
end
