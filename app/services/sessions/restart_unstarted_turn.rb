# frozen_string_literal: true

module Sessions
  # The agent process a monitoring job was sent to adopt is gone, and the runtime
  # never wrote a line under it. Restart the turn instead of parking the session.
  #
  # ## The bug this closes
  #
  # AgentSessionJob's `resume_monitoring` path has exactly one plan: re-attach to
  # the pid recorded in metadata. When that pid turns out to be dead its only other
  # move is to pause the session with `paused_by: "recovery"` and hope a sweep comes
  # round. For a session that had already produced turns that is fine — a resume
  # picks up where it left off. For one whose process died in its first seconds it
  # is not: the session comes to rest in the human action queue with a completely
  # empty transcript, looking exactly like a session asking a question, while the
  # work it was created to do has simply not happened.
  #
  # Production sessions 12265 and 12267 were both caught by the same worker
  # interruption on 2026-09-02. 12265 had made tool calls and was resumed harmlessly.
  # 12267 had produced nothing at all — zero assistant turns, zero tool calls — and
  # sat in `needs_input` for nine and a half minutes until an unrelated orphan sweep
  # happened to reach it.
  #
  # ## Why a restart is safe here, and only here
  #
  # `metadata["runtime_started"]` is written the moment Zimmer records a spawned pid,
  # before the runtime has produced a line, so it cannot answer "is there a
  # conversation worth resuming". RuntimeConversationPresence can, and it is asked of
  # BOTH transcript stores — Zimmer's polled copy and the runtime's own file — so a
  # merely lagging poller can never be enough to conclude that nothing was written.
  #
  # When the answer is "nothing", nothing was consumed and no partial work exists:
  # the stored prompt is exactly what should run, and replaying it is the whole
  # recovery. When the answer is "something", this service declines and the caller's
  # existing resume-with-nudge park is left completely untouched.
  #
  # This is the same judgement ProcessLifecycleManager#handle_empty_turn makes when a
  # process exits under a live monitor, arriving from the other direction: there the
  # turn ended in front of us, here it ended while nobody was watching. They share
  # both the budget and the counter key deliberately — it is one event seen from two
  # vantage points, and a session that has already burned its restarts in-process
  # should not get a second allowance just because the next failure happened to be a
  # worker interruption.
  class RestartUnstartedTurn
    # Shared with ProcessLifecycleManager#handle_empty_turn. See the class comment
    # for why the budget is one budget rather than two.
    MAX_RESTARTS = ProcessLifecycleManager::MAX_EMPTY_TURN_RECOVERIES
    COUNT_KEY = "empty_turn_recovery_count"

    # Records that Zimmer gave up restarting this session, and why, so the park that
    # follows is legible as a decision rather than as the silent empty park this
    # whole service exists to remove.
    ABANDONED_KEY = "unstarted_turn_restart_abandoned"

    Result = Struct.new(:outcome, :message, keyword_init: true) do
      # A fresh turn carrying the session's own prompt is queued.
      def restarted? = outcome == :restarted

      # The budget is spent. The caller must come to rest, saying why.
      def abandoned? = outcome == :abandoned

      # Not this service's case — the caller's own handling applies unchanged.
      def declined? = outcome == :declined
    end

    def self.call(session, **kwargs)
      new(session, **kwargs).call
    end

    # @param session [Session] the session whose process is gone
    # @param working_directory [String, nil] where the runtime was spawned from
    # @param file_system [FileSystemAdapter, nil] adapter for the on-disk lookup
    # @param log_buffer [LogBuffer, nil] the caller's buffer, so the reasoning lands
    #   on the session's own timeline next to the "process is no longer running" line
    def initialize(session, working_directory: nil, file_system: nil, log_buffer: nil)
      @session = session
      @working_directory = working_directory
      @file_system = file_system
      @log_buffer = log_buffer
    end

    # @return [Result]
    def call
      return declined("no prompt to replay") if prompt.blank?
      return declined("the runtime wrote a conversation") if conversation_persisted?

      attempt = restart_count + 1
      return abandon(attempt - 1) if attempt > MAX_RESTARTS

      restart!(attempt)
    rescue => e
      # A recovery that cannot run must not become the thing that breaks the
      # recovery path. Decline, and let the caller's park — the behaviour that was
      # here before this service — happen exactly as it used to.
      Rails.logger.error(
        "[Sessions::RestartUnstartedTurn] Could not restart session #{@session&.id}: #{e.message}"
      )
      add_log("Could not restart the unstarted turn: #{e.message}", level: "error")
      declined(e.message)
    end

    private

    attr_reader :session

    # The best durable prompt to replay. Mirrors ProcessLifecycleManager#recovery_prompt:
    # a follow-up that was in flight when the process died is the turn that was lost,
    # and only a session that never got past its first turn falls back to `prompt`.
    def prompt
      @prompt ||= session.metadata&.dig("active_follow_up_prompt").presence ||
        session.metadata&.dig("sent_message").presence ||
        session.metadata&.dig("pending_follow_up_prompt").presence ||
        session.prompt
    end

    def conversation_persisted?
      RuntimeConversationPresence.persisted?(
        session: session,
        working_directory: @working_directory,
        file_system: @file_system
      )
    end

    def restart_count
      session.metadata&.dig(COUNT_KEY).to_i
    end

    def restart!(attempt)
      add_log(
        "The process is gone and the runtime never wrote a conversation under it — restarting this " \
        "turn from the session's own prompt (attempt #{attempt}/#{MAX_RESTARTS}) rather than parking " \
        "an empty session in the action queue",
        level: "warning"
      )

      # A new runtime session id, for the same reason #handle_empty_turn takes one:
      # neither store holds a conversation, so the old id names nothing a restart
      # would lose — and if the runtime got as far as writing its own bookkeeping
      # under it, re-asserting it is refused as "already in use" (#519).
      reset_runtime_session_id!

      # `deliver_follow_up!` is the one shared delivery path: it drops the stale
      # per-turn metadata, resumes the session, stamps the prompt where the SIGTERM
      # recovery looks for it, enqueues the job and records running_job_id — closing
      # the window in which the session is running with no tracked job, which is the
      # exact shape of the stall this service is fixing.
      #
      # `runtime_started` is stamped false alongside the prompt so the replacement
      # spawn builds `--session-id` rather than `--resume`. Resuming into a
      # conversation we have just established does not exist is how a restart turns
      # into a "no conversation found" park.
      session.deliver_follow_up!(
        prompt,
        clear_metadata_keys: Session::STALE_RETRY_METADATA_KEYS,
        metadata_updates: { COUNT_KEY => attempt, "runtime_started" => false }
      )

      Rails.logger.info(
        "[Sessions::RestartUnstartedTurn] Restarted session #{session.id} from its own prompt " \
        "(attempt #{attempt}/#{MAX_RESTARTS})"
      )
      Result.new(outcome: :restarted, message: "restarted from the session's own prompt (attempt #{attempt})")
    end

    # Claude Code honors the `--session-id` Zimmer supplies, so a fresh id is minted
    # for it. Codex ignores it and mints its own rollout, so the stored id is dropped
    # instead — leaving it would keep transcript polling reading the abandoned
    # rollout forever (ProcessLifecycleManager#release_stale_runtime_session_id!).
    def reset_runtime_session_id!
      if TranscriptRuntime.normalizer_for(session).mints_own_session_id?
        return if session.session_id.blank?

        add_log(
          "Releasing stale runtime session id #{session.session_id} so transcript polling re-attaches " \
          "to the restarted turn's transcript",
          level: "info"
        )
        session.update_column(:session_id, nil)
      else
        new_id = SecureRandom.uuid
        add_log("Replacing unused runtime session id #{session.session_id} with #{new_id}", level: "info")
        session.update_column(:session_id, new_id)
      end
    end

    def abandon(spent)
      message = "the runtime never wrote a conversation, and #{spent} restart(s) did not change that"
      add_log(
        "Not restarting this turn again: #{message}. The session is coming to rest with an empty " \
        "transcript — restart it by hand to try once more.",
        level: "error"
      )
      session.merge_metadata!(ABANDONED_KEY => message)
      Rails.logger.warn(
        "[Sessions::RestartUnstartedTurn] Session #{session.id} abandoned after #{spent} restart(s)"
      )
      Result.new(outcome: :abandoned, message: message)
    end

    def declined(reason)
      Result.new(outcome: :declined, message: reason)
    end

    def add_log(content, level:)
      @log_buffer&.add(content, level: level)
    end
  end
end
