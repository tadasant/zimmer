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
  # worker interruption. Sharing one RetryBudget also means one reset: a stable stretch
  # hands the restarts back to whichever vantage point needs them next (#727).
  class RestartUnstartedTurn
    # Shared with ProcessLifecycleManager#handle_empty_turn — literally the same
    # RetryBudget object, not a copy of its numbers. See the class comment for why the
    # budget is one budget rather than two.
    BUDGET = RetryBudget::EMPTY_TURN

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

      # Reloaded before the budget is read, as ProcessLifecycleManager#
      # empty_turn_recovery_needed? does with the same key: the caller has written to
      # this row several times on the way here, and a stale in-memory `metadata` would
      # under-count the budget.
      session.reload
      attempt = BUDGET.next_attempt(session)
      return abandon(attempt - 1) if BUDGET.exhausted?(session)

      restart!(attempt)
    rescue => e
      # A recovery that cannot run must not become the thing that breaks the
      # recovery path. Decline, so the caller falls through to its own park.
      Rails.logger.error(
        "[Sessions::RestartUnstartedTurn] Could not restart session #{@session&.id}: #{e.message}"
      )
      add_log("Could not restart the unstarted turn: #{e.message}", level: "error")
      declined(e.message)
    end

    private

    attr_reader :session

    # The best durable prompt to replay: a follow-up that was in flight when the
    # process died is the turn that was lost, and only a session that never got past
    # its first turn falls back to `prompt`.
    #
    # ProcessLifecycleManager#recovery_prompt asks the same question and answers it
    # with one more candidate, `active_follow_up_prompt`, which is deliberately NOT
    # consulted here. That key holds `build_prompt_with_goal(...)` OUTPUT — the user's
    # text with the goal block, the session notes and the degraded-MCP block already
    # wrapped around it. PLM hands its answer straight to the CLI adapter; this
    # service hands it to `deliver_follow_up!`, whose job expands it AGAIN. Replaying
    # the expanded form would give the agent the goal instruction twice on the first
    # restart and four times on the second. The three keys below all hold raw text.
    def prompt
      @prompt ||= session.metadata&.dig("sent_message").presence ||
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

    def restart!(attempt)
      add_log(
        "The process is gone and the runtime never wrote a conversation under it — restarting this " \
        "turn from the session's own prompt (attempt #{attempt}/#{BUDGET.max}) rather than parking " \
        "an empty session in the action queue",
        level: "warning"
      )

      # ONE transaction around the id reset and the delivery, and it is load-bearing
      # twice over.
      #
      # `deliver_follow_up!` inserts the job row before it writes `running_job_id`.
      # The caller is a monitoring job that currently OWNS `running_job_id` and is
      # still executing, so a GoodJob scheduler thread picking the new row up in that
      # gap would read the old owner, find it alive, and drop the turn with "Skipping
      # job - session already has a running job" — the exact stall this service
      # exists to remove, reintroduced through a narrower window. Both the INSERT and
      # its NOTIFY become visible only at commit, so inside a transaction there is no
      # gap to lose the turn in. SessionContinuation#continue_with_queued_user_message
      # documents the same hazard from the other side.
      #
      # It also makes the id reset undoable: if the delivery raises, #call rescues to
      # `:declined` and the caller parks exactly as it used to — and the session must
      # not be left carrying an id no spawn ever took.
      ActiveRecord::Base.transaction do
        # A new runtime session id, for the same reason #handle_empty_turn takes one:
        # neither store holds a conversation, so the old id names nothing a restart
        # would lose — and if the runtime got as far as writing its own bookkeeping
        # under it, re-asserting it is refused as "already in use" (#519).
        reset_runtime_session_id!

        # `deliver_follow_up!` is the one shared delivery path: it drops the stale
        # per-turn metadata, resumes the session, stamps the prompt where the SIGTERM
        # recovery looks for it, enqueues the job and records running_job_id — closing
        # the window in which the session is running with no tracked job.
        #
        # `runtime_started` is stamped false alongside the prompt so the replacement
        # spawn builds `--session-id` rather than `--resume`. Resuming into a
        # conversation we have just established does not exist is how a restart turns
        # into a "no conversation found" park.
        session.deliver_follow_up!(
          prompt,
          clear_metadata_keys: Session::STALE_RETRY_METADATA_KEYS,
          metadata_updates: BUDGET.attempt_attributes(attempt).merge("runtime_started" => false)
        )
      end

      Rails.logger.info(
        "[Sessions::RestartUnstartedTurn] Restarted session #{session.id} from its own prompt " \
        "(attempt #{attempt}/#{BUDGET.max})"
      )
      Result.new(outcome: :restarted, message: "restarted from the session's own prompt (attempt #{attempt})")
    end

    # Claude Code honors the `--session-id` Zimmer supplies, so a fresh id is minted
    # for it: the old one names no conversation, and re-asserting one whose transcript
    # file exists is refused as "already in use".
    #
    # Codex ignores the supplied id and mints its own rollout, so the stored id names
    # a rollout the replacement will never write to — and CodexTranscriptSource#
    # find_main_transcript prefers the rollout whose filename carries it, so leaving
    # it set keeps the poller reading the abandoned file (ProcessLifecycleManager#
    # release_stale_runtime_session_id! is the same reasoning). Dropping it is right,
    # but ONLY when the prompt being replayed is the session's own.
    #
    # The scope is not caution, it is the delivery vehicle. PLM releases the id after
    # spawning directly; this service delivers through a follow-up job, and that job
    # reclassifies a follow-up on a session with no `session_id` as a fresh start,
    # which spawns carrying `session.prompt`. That is exactly what we want when
    # `session.prompt` is what we chose to replay — and would silently substitute the
    # first prompt for a lost follow-up otherwise. So a mints-its-own-id runtime keeps
    # its stale id in the follow-up case; the poller re-attaches on the next turn that
    # captures an id, which is strictly better than replaying the wrong turn.
    def reset_runtime_session_id!
      if TranscriptRuntime.normalizer_for(session).mints_own_session_id?
        return if session.session_id.blank?
        return unless prompt == session.prompt

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
