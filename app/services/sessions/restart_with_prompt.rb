# frozen_string_literal: true

module Sessions
  # The one implementation of "resume this session's existing conversation with a
  # prompt" — the restart every recovery path takes when there IS a clone and a
  # `session_id` to prompt into.
  #
  # Like restart-from-scratch, it is reachable from three doors — the session
  # page's Restart button (and its Refresh and bulk-refresh and Start-now
  # callers), `POST /api/v1/sessions/:id/restart`, and MCP `action_session`'s
  # `restart` — and until this class existed each door carried its own verbatim
  # copy of the sequence: pick the prompt, pick the key set, clear, release the
  # job id, resume, enqueue. The copies had drifted in exactly the way
  # [#508](https://github.com/tadasant/zimmer/issues/508) found for the
  # from-scratch branch next door — only the web copy wrapped its transaction in
  # `with_db_retry`, and only the web copy recorded anything on the session's own
  # timeline, so the same operation asked for through the REST API or MCP was
  # fatal on a dropped Postgres connection and left no trace of having happened.
  # This is the retry/recovery slice of
  # [#321](https://github.com/tadasant/zimmer/issues/321).
  #
  # Everything that is the *operation* lives here: the prompt choice, the key set,
  # the transaction, the retry, the two log rows, the resume and the enqueue. Each
  # surface keeps only its own authorization, its own preconditions and its own way
  # of rendering the answer. Same split as `Sessions::RestartFromScratch` — which
  # is this sequence for a session with no conversation to prompt into — and as
  # `Sessions::UpdateCatalogSelection`.
  #
  #   Sessions::RestartWithPrompt.call(session, actor: :web)  # or :api / :mcp
  #
  # ## What stays at the surface, deliberately
  #
  # - **The pause refusal.** MCP and the REST API refuse a session asleep on a
  #   wake-up it has not reached yet; the web UI's Restart button consumes the wake
  #   and takes the session over. A real disagreement between an interactive door
  #   and a non-interactive one, not drift — see
  #   `Mcp::Tools::ActionSession#refuse_if_paused!`.
  # - **The `needs_restart_from_scratch?` dispatch.** It selects a different
  #   operation, with a different answer to render.
  # - **The `session_id` presence check.** All three refuse, in three different
  #   sentences that are part of each surface's contract.
  #
  # ## Why the prompt is chosen inside the transaction
  #
  # `#failed_before_initial_prompt?` reads `metadata["failure_reason"]`, which is in
  # every key set this clears — so the choice has to be made before the clear, on
  # every attempt. Reading it once outside the retry would be correct only until
  # the first retry, which is the point at which it matters.
  class RestartWithPrompt
    include DatabaseRetry

    # `database_unavailable` - the write kept failing on a dropped connection
    # `failed`               - anything else the sequence raised
    Result = Struct.new(:ok, :error, :error_code, keyword_init: true) do
      def ok? = ok
    end

    # How each surface names itself in Zimmer's own log. The session's timeline
    # rows are deliberately identical across the three: they describe what happened
    # to the session, which is the same thing whichever door asked for it.
    ACTOR_LABELS = { web: "the web UI", api: "the REST API", mcp: "MCP" }.freeze

    # @param session [Session] a session with a conversation to prompt into
    # @param actor [Symbol] :web, :api or :mcp — names the caller in Zimmer's log
    # @return [Result]
    def self.call(session, actor: :web)
      new(session, actor: actor).call
    end

    def initialize(session, actor: :web)
      @session = session
      @actor = actor.to_sym
    end

    def call
      # `base_delay` is the controller helper's, not the job helper's. All three
      # doors are request/response — a browser, an HTTP client, an MCP tool call —
      # so somebody is waiting, and 0.3s/0.6s is the budget the web copy always
      # spent. `DatabaseRetry` supplies the retry itself because its give-up path
      # re-raises, where `ControllerDatabaseRetry`'s *renders* and returns false:
      # a service must hand the surface a result to render, not render one itself.
      with_db_retry(base_delay: 0.3) do
        # Re-read the row before every attempt, including the first. A rollback
        # does not restore the in-memory attributes AASM has already changed — it
        # re-marks them dirty — so a second attempt would carry `status` as an
        # unpersisted `waiting` change, write it through `update!` without the
        # state machine, and then find `may_resume?` false and skip `resume!`
        # entirely. That silently drops the resume callbacks: the pending one-time
        # wake would survive a restart that should have cancelled it, and
        # `pending_sleep` (in none of the reset key sets) would survive to drop the
        # session to `waiting` at its next pause.
        @session.reload
        ActiveRecord::Base.transaction { restart! }
      end

      Rails.logger.info(
        "[Sessions::RestartWithPrompt] #{@action_description} initiated for session #{@session.id} " \
        "(requested through #{ACTOR_LABELS.fetch(@actor)})"
      )
      Result.new(ok: true)
    rescue *DatabaseRetry::RETRYABLE_EXCEPTIONS => e
      database_unavailable_error(e)
    rescue => e
      failed_error(e)
    end

    private

    def restart!
      # Both readings have to happen before anything below changes the row:
      # the prompt choice reads `failure_reason` (cleared just below), and the
      # description reads the status `resume!` is about to move off.
      use_initial_prompt = @session.failed_before_initial_prompt? && @session.prompt.present?
      @action_description = action_description

      @session.logs.create!(
        content: "#{@action_description}: " \
                 "#{use_initial_prompt ? 're-sending initial prompt' : 'sending automated recovery prompt'}",
        level: "info"
      )

      # A pre-prompt failure (MCP connection failed, spawn failed, …) also drops
      # `runtime_started` so the restart spawns with `--session-id` instead of
      # `--resume`; both policies, and the two others, are declared together on
      # Session — see Session::PRE_PROMPT_RESTART_KEYS.
      stale_keys = use_initial_prompt ? Session::PRE_PROMPT_RESTART_KEYS : Session::STALE_RETRY_METADATA_KEYS

      @session.remove_metadata!(stale_keys)
      @session.update!(running_job_id: nil)

      # Hand the turn over BEFORE enqueuing the job (the session queues in
      # `waiting`; a worker's `start` runs it). This ensures the resume! callbacks
      # run — clearing the MCP failure flags, the stop record and any armed wake —
      # before the job starts and reads them.
      @session.resume! if @session.may_resume?

      AgentSessionJob.enqueue_with_prompt(
        @session.id, use_initial_prompt ? @session.prompt : AutomatedPrompts::SYSTEM_RECOVERY
      )

      @session.logs.create!(
        content: "Session resumed - its turn is queued for a worker",
        level: "info"
      )
    end

    # Named for the state the session was asked from rather than for the `waiting`
    # it is in a line later. The three states this is reachable from mean different
    # things — a failed session is being recovered, a `needs_input` one taken over,
    # a stalled `waiting` one nudged — and the timeline should say which.
    def action_description
      return "Restarting failed session" if @session.failed?
      return "Continuing waiting session" if @session.waiting?

      "Continuing paused session"
    end

    def database_unavailable_error(error)
      Rails.logger.error(
        "[Sessions::RestartWithPrompt] database unavailable for session #{@session.id}: #{error.message}"
      )
      Result.new(
        ok: false,
        error: "The operation couldn't be completed due to high server activity. Please try again.",
        error_code: :database_unavailable
      )
    end

    # The catch-all. The web copy already swallowed everything here and turned it
    # into a flash; the other two did not, so without this report a genuine bug on
    # this path would now read to an agent as an ordinary refusal and escalate
    # nowhere. ErrorReporter is the seam Zimmer uses to keep deliberate
    # swallow-rescues visible — see its own comment for why.
    def failed_error(error)
      Rails.logger.error(
        "[Sessions::RestartWithPrompt] Error restarting session #{@session.id}: #{error.message}"
      )
      ErrorReporter.report_exception(
        error, context: { session_id: @session.id, service: "Sessions::RestartWithPrompt", actor: @actor }
      )
      log_best_effort("Error resuming session: #{error.message}", level: "error")
      Result.new(ok: false, error: error.message, error_code: :failed)
    end

    # The failure is recorded on the session's own timeline, which is where a human
    # looks — but a database that just refused the write is not a reason to raise
    # something else on the way out.
    def log_best_effort(content, level:)
      @session.logs.create!(content: content, level: level)
    rescue StandardError => e
      Rails.logger.warn "[Sessions::RestartWithPrompt] could not log to session #{@session.id}: #{e.message}"
      nil
    end
  end
end
