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
  # the prompt where they can read it.
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
  # ## The five conditions, and why each one is load-bearing
  #
  # 1. **Nothing was spawned.** The caller answers this from
  #    `ProcessLifecycleManager#current_pid` and its own local pid, so the question
  #    is "did THIS job start an agent", not "is there an agent somewhere". A turn
  #    that died after its process existed is a runtime fault with a transcript to
  #    read; it keeps the `failed` path untouched.
  # 2. **No further attempt is queued.** `AgentSessionJob` declares `retry_on` for
  #    three transient exception classes, and #perform re-raises, so a turn dying on
  #    one of them is not over — another attempt will run this same prompt. Parking
  #    it would announce in the action queue that the turn had ended while a retry
  #    was still queued, and a human acting on that announcement would race the
  #    retry into delivering the prompt twice. Those keep the `failed` path they
  #    have always had; the caller decides, since `retry_on` is its declaration.
  # 3. **The turn carried a prompt.** An undelivered prompt is what makes this a
  #    person's problem rather than a machine's. A promptless turn dying at boot
  #    has nothing a human is waiting on.
  # 4. **The session is `running`.** `pause` transitions from `running` only, and
  #    `running` is exactly the state a delivered follow-up is in — every path that
  #    hands a prompt to a job resumes first. A session still `waiting` is having
  #    its FIRST turn set up, which is a different case: nobody has been told the
  #    work started, and its failure is in front of the person who just created it.
  # 5. **Not a status-summary fork.** Zimmer's own bookkeeping, which must never
  #    take a slot in the action queue or page anyone — the same carve-out
  #    `SessionStateMachine`'s `pause` callback makes.
  #
  # ## Where the prompt is kept, and where it is deliberately NOT kept
  #
  # The prompt goes into `undelivered_prompt`, a key this park owns and nothing
  # else consumes, and into the session's own timeline so a human can read it
  # without a database.
  #
  # It is emphatically NOT put back in `pending_follow_up_prompt`, which is the
  # obvious-looking place and is a trap. #perform's follow-up arm reads
  # `pending_follow_up_prompt || follow_up_prompt`, so a stale value there WINS over
  # the next turn's real prompt — the job says so itself, in the comment above the
  # marker it drops when it reclassifies a follow-up as a fresh start. Three
  # delivery paths enqueue a prompt without stamping the marker (the REST
  # `follow_up` endpoint, MCP `action_session`'s direct follow-up, and
  # `EnqueuedMessageProcessorService`), so all three would deliver the parked prompt
  # in place of the one a human just sent. The third is reachable from this park's
  # own `pause!`, which drains the queued-message backlog: a message queued while
  # the turn ran would be destroyed on the way out and the parked prompt delivered
  # instead of it.
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
    # page's failure block, `Session#failure_summary`, the push body — can tell this
    # park from an ordinary `pause`. Cleared by the `resume` callback, so a session
    # that runs again does not keep rendering a failure it has moved past.
    FAILURE_REASON = "undelivered_turn"

    # Where the prompt nobody saw is kept. Owned by this park: nothing else writes
    # it and nothing consumes it automatically. See the class comment for why it is
    # not `pending_follow_up_prompt`.
    PROMPT_KEY = "undelivered_prompt"

    # Metadata this park writes, and which `resume` therefore drops. A session that
    # is running again has moved past all of it.
    METADATA_KEYS = %w[failure_reason exception_class exception_message undelivered_prompt].freeze

    # Cap on the prompt echoed into the session's timeline. Generous, because this
    # copy is the one a human reads and re-sends by hand — but bounded, because a
    # 500,000-character prompt is a legal one and the timeline is a UI.
    PROMPT_LOG_MAX_CHARS = 4_000

    # @param session [Session]
    # @param error [Exception] the exception #perform's catch-all caught
    # @param prompt [String, nil] the prompt this turn was carrying
    # @param spawned [Boolean] whether this job started an agent process
    # @param retry_pending [Boolean] whether the caller is about to have this
    #   exception retried — see condition 2 in the class comment
    # @param log_buffer [LogBuffer, nil] the caller's buffer, so the disposition
    #   lands on the session's own timeline next to the error it explains
    # @return [Boolean] true when the session was parked and the caller must not
    #   also fail it
    def self.call(session, **kwargs)
      new(session, **kwargs).call
    end

    def initialize(session, error:, prompt:, spawned:, retry_pending: false, log_buffer: nil)
      @session = session
      @error = error
      @prompt = prompt
      @spawned = spawned
      @retry_pending = retry_pending
      @log_buffer = log_buffer
    end

    def call
      return false if @spawned
      return false if @retry_pending
      return false if @prompt.blank?

      # Re-read the row before deciding from it. The setup this rescue sits at the
      # end of runs for minutes, and the session object the job has carried since
      # before the clone is not evidence of what the row says now.
      session.reload
      return false unless session.running?
      return false if session.status_summary_fork?

      # merge_metadata!, not a whole-column write: `pending_follow_up_prompt` is one
      # of the keys AtomicJsonMetadata exists to protect, and a read-modify-write of
      # the whole column here would drop whatever another writer set during the
      # minutes of setup that just failed. It skips validations too, which matters
      # for the same reason the loud path uses update_columns — the exception being
      # handled may itself be a validation failure.
      session.merge_metadata!(
        "failure_reason" => FAILURE_REASON,
        "exception_class" => @error.class.name,
        "exception_message" => @error.message.to_s.truncate(AgentSessionJob::EXCEPTION_MESSAGE_MAX_CHARS),
        PROMPT_KEY => @prompt
      )

      add_log(
        "This turn stopped before the agent started, so the prompt it was carrying was never delivered " \
        "(#{@error.class.name}). Nothing ran and nothing is retried — the session is coming to rest in the " \
        "action queue rather than failing where nobody looks. The prompt is kept below, and on the session " \
        "as `#{PROMPT_KEY}`, so it can be sent again by hand:\n\n" \
        "#{@prompt.to_s.truncate(PROMPT_LOG_MAX_CHARS)}",
        level: "warning"
      )

      # `pause` clears `running_job_id` itself, in cleanup_running_job.
      session.pause! if session.may_pause?

      # The answer is the row, not the intent. A row that moved between the reload
      # above and here leaves `pause!` unrun, and answering true then would skip the
      # caller's `fail!` and strand the session `running` with nobody driving it.
      parked = session.reload.needs_input?
      if parked
        Rails.logger.warn(
          "[Sessions::ParkUndeliveredTurn] Session #{session.id} parked in needs_input: its turn raised " \
          "#{@error.class.name} before the agent started, and the prompt was never delivered"
        )
      end
      parked
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
