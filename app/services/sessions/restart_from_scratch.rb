# frozen_string_literal: true

module Sessions
  # The one implementation of "throw this session's clone away and re-run the whole
  # setup pipeline".
  #
  # Restart from scratch is reachable from three doors — the session page's Restart
  # button, `POST /api/v1/sessions/:id/restart`, and MCP `action_session`'s
  # `restart` — and until this class existed each door carried its own verbatim
  # copy of the sequence. They had already drifted in the way copies do: the web
  # copy wrapped its transaction in `with_db_retry` and the other two did not, so a
  # dropped Postgres connection during a restart was retried from the browser and
  # came back as a 500 or a `ToolError` from the API and from MCP — on the one
  # operation whose entire point is recovering a session that is already broken
  # ([#508](https://github.com/tadasant/zimmer/issues/508)).
  #
  # Everything that is the *operation* lives here: the git_root guard, the key set,
  # the transaction, the retry, the two log rows, the resume, the enqueue and the
  # job-id claim. Each surface keeps only its own authorization and its own way of
  # rendering the answer. This is the same split `Sessions::UpdateCatalogSelection`
  # makes, and the sibling of `Session#deliver_follow_up!` — which is this sequence
  # for a session that still has a conversation to prompt into.
  #
  #   Sessions::RestartFromScratch.call(session, actor: :web)  # or :api / :mcp
  #
  # ## What the pause guard is NOT
  #
  # Refusing a session that is asleep on a wake-up it has not reached yet stays at
  # the surface, deliberately, because the three surfaces genuinely disagree about
  # it: MCP and the REST API refuse (an agent working a ranked queue must not start
  # a session that asked to be left alone), and the web UI's Restart button does
  # not (a person clicking Restart on one session is taking it over, and consuming
  # the now-moot wake is the documented behaviour). See
  # `Mcp::Tools::ActionSession#refuse_if_paused!`. Only the things all three agree
  # on moved in here.
  #
  # ## The attachments come along
  #
  # The replacement turn IS the original first turn — same prompt, new clone, new
  # `session_id` — so it carries the attachments that turn was created with.
  # `AgentSessionJob` reads images and files ONLY out of its job arguments, so
  # enqueuing bare re-ran "here is the screenshot, fix this" without the screenshot
  # ([#746](https://github.com/tadasant/zimmer/issues/746)). Replaying all of them
  # is deliberate rather than incidental: this path is reached only when there is
  # no conversation to prompt into — a pre-prompt failure with setup incomplete, or
  # a session that never ran — so nothing was ever delivered to an agent, and the
  # restart has just discarded whatever conversation an earlier delivery went to.
  #
  # The read happens OUTSIDE the transaction (a slow volume must not hold it open)
  # and never raises: this path is taken when something has already gone wrong, so
  # a storage tree that cannot be read costs the attachments, never the restart.
  #
  # ## `running_job_id` is claimed, not left blank
  #
  # The three copies set `running_job_id: nil` and enqueued without recording the
  # new job's id, which leaves the session `running` with no tracked job until the
  # job actually starts. `DeploymentRecoveryJob#orphaned_running_session?` treats a
  # blank `running_job_id` on a `running` session as orphaned with **no grace
  # period**, so a recovery pass landing in that window starts a second turn
  # against the session this one just restarted. Claiming the id closes the window,
  # exactly as `Session#deliver_follow_up!` does and for the same reason;
  # `AgentSessionJob`'s concurrency guard skips itself (`running_job_id != job_id`),
  # so the job it names is not blocked by its own claim.
  class RestartFromScratch
    include DatabaseRetry

    # `no_git_root`          - there is no repository to clone; nothing to restart
    # `database_unavailable` - the write kept failing on a dropped connection
    # `failed`               - anything else the sequence raised
    Result = Struct.new(:ok, :error, :error_code, keyword_init: true) do
      def ok? = ok
    end

    # How each surface names itself in Zimmer's own log. The session's timeline
    # rows are deliberately identical across the three: they describe what happened
    # to the session, which is the same thing whichever door asked for it.
    ACTOR_LABELS = { web: "the web UI", api: "the REST API", mcp: "MCP" }.freeze

    # @param session [Session]
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
      return no_git_root_error if @session.git_root.blank?

      images, files = Sessions::FirstTurnAttachments.for(@session)
      carrying = Sessions::FirstTurnAttachments.carrying_clause(images, files)

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
        # unpersisted `running` change, write it through `update!` without the
        # state machine, and then find `may_resume?` false and skip `resume!`
        # entirely. That silently drops the resume callbacks: the pending
        # one-time wake would survive a restart that should have cancelled it,
        # and `pending_sleep` (in none of the reset key sets) would survive to
        # drop the session to `waiting` at its next pause.
        @session.reload
        ActiveRecord::Base.transaction { restart!(images, files, carrying) }
      end

      Rails.logger.info(
        "[Sessions::RestartFromScratch] Restart from scratch initiated for session #{@session.id} " \
        "(requested through #{ACTOR_LABELS.fetch(@actor)})"
      )
      Result.new(ok: true)
    rescue *DatabaseRetry::RETRYABLE_EXCEPTIONS => e
      database_unavailable_error(e)
    rescue => e
      failed_error(e)
    end

    private

    def restart!(images, files, carrying)
      @session.logs.create!(
        content: "Restarting session from scratch: re-running full setup pipeline " \
                 "(git clone, MCP config, process spawn)#{carrying}",
        level: "info"
      )

      @session.remove_metadata!(Session::RESTART_FROM_SCRATCH_KEYS)
      @session.update!(running_job_id: nil, session_id: nil)
      @session.resume! if @session.may_resume?

      # A new session rather than a follow-up: that is what re-runs the whole setup
      # pipeline — git clone, MCP configuration, skill injection, process spawn.
      job = AgentSessionJob.enqueue_new_session(
        @session.id, images: images.presence, files: files.presence
      )
      claim_running_job(job)

      @session.logs.create!(
        content: "Session resumed - status changed to running, full setup will be re-attempted",
        level: "info"
      )
    end

    # Record the enqueued job's id so the session is never `running` with nothing
    # for orphan detection to look at. See the class comment.
    def claim_running_job(job)
      job_id = job.try(:job_id)

      if job_id.present?
        @session.update!(running_job_id: job_id)
      else
        # ActiveJob's contract lets `perform_later` return false when a callback
        # aborts the enqueue. No job registers such a callback today, so this is
        # unreachable rather than tolerated — but if it ever fires, the session is
        # left `running` with no job and nothing for orphan detection to find. Say
        # so loudly; the restart itself still happened, so it is not an error the
        # caller can act on.
        Rails.logger.error(
          "[Sessions::RestartFromScratch] Session #{@session.id} was resumed but " \
          "AgentSessionJob.enqueue_new_session returned no job id — the session is running " \
          "with no tracked job"
        )
      end
    end

    def no_git_root_error
      message = "cannot restart from scratch: no git_root configured"
      log_best_effort("Cannot restart session: #{message}", level: "warning")
      Result.new(ok: false, error: message, error_code: :no_git_root)
    end

    def database_unavailable_error(error)
      Rails.logger.error(
        "[Sessions::RestartFromScratch] database unavailable for session #{@session.id}: #{error.message}"
      )
      Result.new(
        ok: false,
        error: "The operation couldn't be completed due to high server activity. Please try again.",
        error_code: :database_unavailable
      )
    end

    # The catch-all. Two of the three surfaces already swallowed everything here
    # and turned it into a rendered error; the MCP one did not, so without this
    # report a genuine bug on this path would now read to an agent as an ordinary
    # refusal and escalate nowhere. ErrorReporter is the seam Zimmer uses to keep
    # deliberate swallow-rescues visible — see its own comment for why.
    def failed_error(error)
      Rails.logger.error(
        "[Sessions::RestartFromScratch] Error restarting session #{@session.id} from scratch: #{error.message}"
      )
      ErrorReporter.report_exception(
        error, context: { session_id: @session.id, service: "Sessions::RestartFromScratch", actor: @actor }
      )
      log_best_effort("Error restarting session from scratch: #{error.message}", level: "error")
      Result.new(ok: false, error: error.message, error_code: :failed)
    end

    # The refusal and the failure are both recorded on the session's own timeline,
    # which is where a human looks — but a database that just refused the write is
    # not a reason to raise something else on the way out.
    def log_best_effort(content, level:)
      @session.logs.create!(content: content, level: level)
    rescue StandardError => e
      Rails.logger.warn "[Sessions::RestartFromScratch] could not log to session #{@session.id}: #{e.message}"
      nil
    end
  end
end
