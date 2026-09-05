# frozen_string_literal: true

module Sessions
  # The clone a session was running in is gone from disk, and the session has a
  # conversation worth keeping. Rebuild the tree and resume, instead of failing the
  # session terminally.
  #
  # ## The bug this closes (zimmer#817)
  #
  # One fault — the clone directory is not there — reached two code paths in
  # AgentSessionJob and got two different answers. The follow-up path recreates the
  # clone from the session row's `git_root` / `branch` / `subdirectory`, restores the
  # transcript and carries on. The `resume_monitoring` validator returned "clone
  # directory not found at <path>" and the session went to `failed`, which is
  # terminal: `failed` rejects `follow_up`, so the only thing left for a human is to
  # hand-respawn the task as a brand-new session, losing the session's identity, its
  # transcript and its place in the hierarchy that spawned it.
  #
  # Production session 12280 took the second path after running for two hours and ten
  # minutes. The issue reports that sessions 12256 and 11907 hit the same fault in the
  # same five-minute window, took the follow-up path instead, and carried on.
  #
  # ## What is recovered, and what is not
  #
  # The uncommitted work in the lost tree is gone and nothing here pretends otherwise
  # — the recovery is a fresh `git clone`, so it recovers the session, not the diff.
  # What survives is what a re-spawn destroys: the row, the runtime session id, the
  # polled transcript, the parent/child links, the goal, the PR the session is
  # holding. The agent is told plainly what it lost — see
  # AutomatedPrompts::LOST_CLONE_RECOVERY_TEMPLATE, which exists because a
  # SYSTEM_RECOVERY nudge here would invite it to carry on against a tree that no
  # longer matches a word of its own transcript.
  #
  # ## Why this does not re-clone anything itself
  #
  # It delivers a follow-up turn, and AgentSessionJob's follow-up path is what
  # rebuilds the clone. That path already re-clones a missing directory back to its
  # previous location (SessionClonePath#for_recreate, so the transcript directory
  # keeps one slug — #576), adopts a subdirectory that moved in the catalog (#921),
  # retries a transient clone failure, restores a regressed on-disk transcript and
  # refuses to resume when it cannot (#519), and re-runs `air prepare`. Duplicating
  # any of that here would be a second implementation of the branch this issue is
  # about having only one of.
  #
  # ## The boundary
  #
  # Too permissive is its own bug: a session resumed after side effects have already
  # been taken re-does them (#716, #801). Four things must hold, and the caller falls
  # back to the existing terminal failure whenever one does not.
  #
  # 1. **`git_root` is present.** There is nothing to rebuild the tree from otherwise.
  # 2. **The recorded agent process is not running.** A live process means something
  #    is still driving this session, and delivering a turn would spawn a second agent
  #    against one session (#400). Asked by the caller, which owns the process manager.
  # 3. **Zimmer's stored transcript holds a conversation.** No conversation means
  #    there is nothing to resume into — and that case already has an owner in
  #    Sessions::RestartUnstartedTurn, which the caller tries first.
  # 4. **The budget is not spent** (RetryBudget::LOST_CLONE, 2). A clone that keeps
  #    vanishing is a broken volume, not a session to retry forever.
  class RecoverLostClone
    BUDGET = RetryBudget::LOST_CLONE

    # Records that Zimmer gave up rebuilding this session's tree, and why, so the
    # terminal failure that follows is legible as a decision rather than as the
    # unconditional failure this service exists to remove.
    ABANDONED_KEY = "lost_clone_recovery_abandoned"

    Result = Struct.new(:outcome, :message, keyword_init: true) do
      # A turn carrying the lost-clone notice is queued; the follow-up path will
      # rebuild the tree before it runs.
      def recovered? = outcome == :recovered

      # The budget is spent. The caller fails the session, saying so.
      def abandoned? = outcome == :abandoned

      # Not this service's case — the caller's existing handling applies unchanged.
      def declined? = outcome == :declined
    end

    def self.call(session, **kwargs)
      new(session, **kwargs).call
    end

    # @param session [Session] the session whose clone is gone
    # @param clone_path [String, nil] where the clone was, for the log line
    # @param log_buffer [LogBuffer, nil] the caller's buffer, so the reasoning lands on
    #   the session's own timeline next to the validation failure that sent us here
    def initialize(session, clone_path: nil, log_buffer: nil)
      @session = session
      @clone_path = clone_path
      @log_buffer = log_buffer
    end

    # @return [Result]
    def call
      return declined("the session has no git_root to rebuild the clone from") if session.git_root.blank?
      return declined("Zimmer's stored transcript holds no conversation to resume into") unless conversation?

      # Reloaded before the budget is read, as Sessions::RestartUnstartedTurn does with
      # the same key: the caller has written to this row on the way here, and a stale
      # in-memory `metadata` would under-count the budget.
      session.reload
      return abandon(BUDGET.count_for(session)) if BUDGET.exhausted?(session)

      recover!(BUDGET.next_attempt(session))
    rescue => e
      # A recovery that cannot run must not become the thing that breaks the failure
      # path. Decline, so the caller fails the session exactly as it used to.
      Rails.logger.error(
        "[Sessions::RecoverLostClone] Could not recover session #{@session&.id}: #{e.message}"
      )
      add_log("Could not rebuild the missing clone: #{e.message}", level: "error")
      declined(e.message)
    end

    private

    attr_reader :session

    def conversation?
      RuntimeConversationPresence.stored_conversation?(session)
    end

    def branch
      session.branch.presence || "main"
    end

    def recover!(attempt)
      add_log(
        "The clone at #{@clone_path || "the recorded path"} is gone, so there is nothing to resume " \
        "into — rebuilding the working tree from #{session.git_root} (branch: #{branch}) and resuming " \
        "this conversation (attempt #{attempt}/#{BUDGET.max}) rather than failing the session. " \
        "Uncommitted work in the lost tree cannot be recovered.",
        level: "warning"
      )

      # ONE transaction around the delivery, for the reason Sessions::RestartUnstartedTurn
      # spells out: `deliver_follow_up!` inserts the job row before it writes
      # `running_job_id`, and the caller is a monitoring job that currently OWNS
      # `running_job_id` and is still executing. A GoodJob scheduler thread picking the
      # new row up in that gap would read the old owner, find it alive, and drop the turn
      # with "Skipping job - session already has a running job". Inside a transaction the
      # INSERT and its NOTIFY become visible only at commit, so there is no gap.
      ActiveRecord::Base.transaction do
        session.deliver_follow_up!(
          AutomatedPrompts.lost_clone_recovery(git_root: session.git_root, branch: branch),
          # The same stale per-turn keys every other recovery drops. `clone_path` and
          # `working_directory` are deliberately left alone: the follow-up path reads
          # `clone_path` to decide the tree is missing and hands it to
          # SessionClonePath#for_recreate, which is what keeps the rebuilt clone — and
          # therefore the runtime's transcript directory — at one path for the life of
          # the conversation (#576).
          clear_metadata_keys: Session::STALE_RETRY_METADATA_KEYS,
          metadata_updates: BUDGET.attempt_attributes(attempt)
        )
      end

      Rails.logger.info(
        "[Sessions::RecoverLostClone] Rebuilding the clone for session #{session.id} and resuming " \
        "(attempt #{attempt}/#{BUDGET.max})"
      )
      Result.new(outcome: :recovered, message: "rebuilding the clone and resuming (attempt #{attempt})")
    end

    def abandon(spent)
      message = "the clone has gone missing again after #{spent} rebuild(s)"
      add_log(
        "Not rebuilding this session's clone again: #{message}. A tree that will not stay on disk is " \
        "an infrastructure problem, not a session to retry — the session is failing so somebody looks " \
        "at the volume.",
        level: "error"
      )
      session.merge_metadata!(ABANDONED_KEY => message)
      Rails.logger.warn(
        "[Sessions::RecoverLostClone] Session #{session.id} abandoned after #{spent} rebuild(s)"
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
