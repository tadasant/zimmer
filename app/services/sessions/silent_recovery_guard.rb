# frozen_string_literal: true

module Sessions
  # Bound the number of times Zimmer's own recovery may restart a session that
  # answers with nothing at all, and fail the session when the bound is reached.
  #
  # ## The defect this closes (zimmer#988)
  #
  # Zimmer's recovery sweeps are a loop with no exit. `CleanupOrphanedSessionsJob`
  # calls a `running` session hung when its `last_timeline_entry_at` is 15 minutes
  # old; `SessionRecoveryService` terminates the recorded pid, parks the session in
  # `needs_input` and immediately restarts it; the restart transitions the session
  # back to `running`, and `start`/`resume` call `reset_elapsed_time_counter`, which
  # sets `last_timeline_entry_at` to *now*. Fifteen minutes later the same sweep
  # reaches the same verdict about the same session.
  #
  # That loop is correct while the restarts work, and they usually do. What nothing
  # bounded was the case where they do not work at all. Production session 14313 sat
  # `running` for 92 minutes with its agent process gone (`ps -p 65662` empty), its
  # transcript file frozen at 11:19:16Z, its `broadcast_mcp_log_count` frozen at 45,
  # and `needs_input_count` climbing 2 → 5 as recovery re-queued job after job — none
  # of which wrote a single transcript line. Sessions 14391, 14474 and 14501 repeated
  # it, one of them for three hours, across two agent roots and two clones. The
  # `process_identity` blob was byte-identical across every relaunch, which is the
  # proof that no restart ever reached a spawn: a genuinely new process on the same
  # host cannot reproduce an old one's `started_at_ticks`.
  #
  # Nothing surfaced any of it. The status stayed `running`, so no `session_failed`
  # fired, no push went out, no parent's wake trigger tripped, and the session
  # occupied a slot indefinitely. The person whose queued work never landed was the
  # one who eventually noticed.
  #
  # This guard does not diagnose why a restart produces nothing — the wedge point is
  # somewhere between `job_started_at` being stamped and the runtime writing its
  # first line, and it may not be one place. It bounds the consequence, which is the
  # half that must not depend on the diagnosis: after
  # `RetryBudget::SILENT_RECOVERY.max` restarts that started a turn and wrote
  # nothing, the session comes to rest in `failed` with
  # `failure_reason: "recovery_produced_no_output"`, which is a state a human, a
  # parent session's wake trigger and the fleet's own health surface can all see.
  #
  # ## Why the verdict needs TWO facts, not one
  #
  # "This session has produced no output" is not enough on its own, and reading it as
  # enough is how a guard like this strands healthy sessions. Two of Zimmer's
  # ordinary states produce no output for long stretches on purpose:
  #
  #   * a session held in the spot queue, or parked for an auth/quota outage — the
  #     platform denied it compute, and [production invariant 6] says an interval in
  #     which compute was denied must never be charged against a bound; and
  #   * a session that is simply slow — a long tool call, a compaction, a subagent
  #     working for twenty minutes.
  #
  # So the guard spends an attempt only when BOTH halves hold:
  #
  #   1. **The turn actually started.** `metadata["job_started_at"]` advanced since
  #      the last restart. `AgentSessionJob` stamps that key only after every
  #      stand-down guard has passed — `SpotSessionHold.hold_if_needed`, the pause
  #      guard, the archived guard, the concurrency guard all return *above* it — so
  #      a spot hold, a quota hold and a superseded turn each leave it unchanged, and
  #      each is therefore invisible to this budget by construction.
  #   2. **The turn wrote nothing.** `session.transcript_line_count` is unchanged.
  #      That counts transcript events, and it is written by `TranscriptPollerService`
  #      alone, so unlike `last_timeline_entry_at` a state transition cannot advance
  #      it. A slow session that eventually says anything at all — one tool call, one
  #      assistant message — moves it, and moving it does not merely stop the count,
  #      it hands the whole budget back.
  #
  # The second half is also why an exhausted counter can never fail a session on its
  # own: reaching the cap is not what fails a session, a *fresh* silent restart while
  # the cap is already spent is. A session that recovered — by a human's restart, by
  # a later sweep, by anything — is read as `:progress` on the next pass and starts
  # again from zero.
  #
  # ## What it does NOT bound
  #
  # A restart that spawns a process which then produces nothing is the *empty turn*,
  # and `RetryBudget::EMPTY_TURN` has bounded it from both vantage points since #727.
  # This budget is for the case where no spawn happens at all, which is why the two
  # do not share a counter: they are different failures with different evidence.
  class SilentRecoveryGuard
    BUDGET = RetryBudget::SILENT_RECOVERY

    # The fingerprint of "what this session had produced" when recovery last
    # restarted it. Two scalars, both read straight off the row.
    WATERMARK_KEY = "silent_recovery_watermark"
    WATERMARK_JOB_STARTED_AT = "job_started_at"
    WATERMARK_TRANSCRIPT_LINES = "transcript_lines"

    # Written to `failure_reason`, so `Session#failure_summary`, the session page's
    # metadata panel and the `#eng-alerts` orphaned-trigger report all name the same
    # thing. Deliberately distinct from `unstarted_turn_not_recoverable`, which is
    # the empty-turn give-up: that one has a process behind it and this one does not.
    FAILURE_REASON = "recovery_produced_no_output"

    Result = Struct.new(:outcome, :message, keyword_init: true) do
      # Recovery may restart this session.
      def proceed? = outcome != :gave_up

      # The budget is spent and the session has been failed. The caller must not
      # restart it.
      def gave_up? = outcome == :gave_up
    end

    # @param session [Session]
    # @param source [String] the sweep or service about to restart the session,
    #   named on the session's own timeline so "why did this fail" is answerable
    #   from the session page alone
    # @param log_buffer [LogBuffer, nil]
    # @return [Result]
    def self.call(session, source:, log_buffer: nil)
      new(session, source: source, log_buffer: log_buffer).call
    end

    def initialize(session, source:, log_buffer: nil)
      @session = session
      @source = source
      @log_buffer = log_buffer
    end

    # @return [Result]
    def call
      # Reloaded before the counter is read, for the reason
      # Sessions::RestartUnstartedTurn reloads: the callers have written to this row
      # several times on the way here, and a stale in-memory `metadata` under-counts
      # the budget — which fails in the direction of never bounding anything.
      session.reload

      # An archived session takes no turn, so there is no restart here to judge — and
      # spending its budget would sabotage the recovery owed to it if it is ever
      # unarchived, which is the same reason SessionContinuation#refuse_recovery_turn
      # keeps its own budget off that case. Neither sweep selects an archived session,
      # so this is a belt rather than a branch that fires.
      return Result.new(outcome: :proceed, message: "session is archived") if session.archived?

      current = fingerprint
      verdict = judge(current)

      case verdict
      when :silent
        spend(current)
      when :progress
        hand_budget_back(current)
      when :first
        record_watermark(current)
        Result.new(outcome: :proceed, message: "first recovery restart of this session")
      else # :not_started — the previous restart never got a turn, so it is not evidence
        Result.new(outcome: :proceed, message: "the previous recovery restart never started a turn")
      end
    rescue => e
      # A guard on the recovery path must never become the reason a recoverable
      # session is not recovered. Proceeding is the pre-existing behaviour.
      Rails.logger.error(
        "[Sessions::SilentRecoveryGuard] Could not assess session #{@session&.id}: #{e.class}: #{e.message}"
      )
      Result.new(outcome: :proceed, message: "guard could not run: #{e.message}")
    end

    private

    attr_reader :session, :source

    # What this session has produced, as of now.
    # @return [Hash]
    def fingerprint
      {
        WATERMARK_JOB_STARTED_AT => session.metadata&.dig("job_started_at"),
        WATERMARK_TRANSCRIPT_LINES => session.transcript_line_count.to_i
      }
    end

    # @return [Symbol] :first, :progress, :not_started or :silent
    def judge(current)
      previous = session.metadata&.dig(WATERMARK_KEY)
      return :first if previous.blank?

      # An outage park denied this session compute rather than answering with
      # silence. Quota depletion is budget pacing, not a failure signal, so the
      # interval never reaches the budget. (A spot hold cannot reach here at all —
      # it returns above `job_started_at` — but an auth-outage park is taken by a
      # job that has already stamped it, so this check is the one that covers it.)
      return :not_started if AuthOutageParkService.parked?(session)

      # A turn that never started is not evidence either way: something stood the
      # restart down (a hold, a supersession, a concurrent job) before the job
      # stamped `job_started_at`.
      job_started = current[WATERMARK_JOB_STARTED_AT]
      return :not_started if job_started.blank? ||
        job_started.to_s == previous[WATERMARK_JOB_STARTED_AT].to_s

      return :progress if current[WATERMARK_TRANSCRIPT_LINES] != previous[WATERMARK_TRANSCRIPT_LINES].to_i

      :silent
    end

    # The last restart started a turn and wrote nothing. Spend one attempt, or give
    # up if there are none left.
    def spend(current)
      attempt = BUDGET.next_attempt(session)
      return give_up(attempt - 1) if BUDGET.exhausted?(session)

      BUDGET.record!(session, attempt: attempt, extra: { WATERMARK_KEY => current })
      add_log(
        "The last recovery restart of this session started a turn at " \
        "#{current[WATERMARK_JOB_STARTED_AT]} and produced no transcript output. Restarting again " \
        "(attempt #{attempt} of #{BUDGET.max}) — after that this session is failed rather than " \
        "restarted, so it stops looking healthy while producing nothing.",
        level: "warning"
      )
      Result.new(outcome: :proceed, message: "silent restart #{attempt} of #{BUDGET.max}")
    end

    # The last restart produced transcript output, so the incident is over.
    def hand_budget_back(current)
      previous_count = BUDGET.count_for(session)
      session.merge_metadata!({ WATERMARK_KEY => current }, BUDGET.clears)
      if previous_count.positive?
        add_log(
          "#{BUDGET.counter_label} reset (was #{previous_count}) — the last recovery restart " \
          "produced transcript output, so this session is being recovered rather than looping.",
          level: "info"
        )
      end
      Result.new(outcome: :proceed, message: "the previous recovery restart produced output")
    end

    # Stop restarting, and say so in the one state a human, a parent session's wake
    # trigger and the health surface all read: `failed`.
    def give_up(spent)
      message =
        "Zimmer's recovery restarted this session #{spent} times (#{source}) and not one of those " \
        "turns produced a single transcript event. Failing it rather than restarting again: a " \
        "session whose restarts produce nothing is not running, and reporting it as `running` " \
        "hides it from everyone waiting on its work. Restart it to try once more."
      add_log(message, level: "error")

      # `paused_by` goes, and dropping it is load-bearing. Both recovery sweeps
      # select `paused_by = 'recovery'` — CleanupOrphanedSessionsJob's failed-session
      # branch matches it on `failed` too — so leaving it behind would hand the
      # session straight back to the loop this give-up exists to end.
      session.merge_metadata!({ "failure_reason" => FAILURE_REASON }, [ "paused_by" ])
      session.update!(running_job_id: nil)
      session.fail! if session.may_fail?

      Rails.logger.warn(
        "[Sessions::SilentRecoveryGuard] Failed session #{session.id} after #{spent} silent " \
        "recovery restarts (#{source})"
      )
      Result.new(outcome: :gave_up, message: "#{spent} recovery restarts produced no output")
    end

    def record_watermark(current)
      session.merge_metadata!(WATERMARK_KEY => current)
    end

    def add_log(content, level:)
      if @log_buffer
        @log_buffer.add(content, level: level)
      else
        session.logs.create!(content: content, level: level)
      end
    rescue => e
      Rails.logger.warn("[Sessions::SilentRecoveryGuard] Could not write session log: #{e.message}")
    end
  end
end
