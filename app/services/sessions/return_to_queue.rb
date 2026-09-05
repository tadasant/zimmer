# frozen_string_literal: true

module Sessions
  # Zimmer has given up on a session that never ran. Put it back in `waiting`,
  # not in the human action queue.
  #
  # ## The bug this closes (#602)
  #
  # `needs_input` is the homepage's action list — the set of sessions a person is
  # expected to decide something about. A session that was interrupted while its
  # first job was starting, or that the spot gate held before it was ever
  # dispatched, has nothing to ask: it is waiting for compute, which is what
  # `waiting` already models. Resting it in `needs_input` is wrong twice over.
  # It takes a slot in the queue, and nothing ever re-queues it — the fleet's
  # start paths all read `waiting`, so the work simply never happens.
  #
  # Two populations were counted on 2026-08-22, both of them spot sessions:
  # ~28 interrupted at start on 2026-08-20 (`interrupted_start_requeue_count`, a
  # `job_started_at`, and a transcript holding only the spawn prompt), and a pair
  # held by the gate at `at_utilization_limit` and then abandoned by a recovery
  # pass with `recovery_continue_abandoned: "no session_id found, working
  # directory not found or invalid"`. 42 spot-class sessions were in `needs_input`
  # at the sweep; exactly one of them was there for a sanctioned reason.
  #
  # ## Where it is called from
  #
  # The two points at which Zimmer stops trying to continue a session it paused
  # for its own recovery, and would otherwise leave it wherever the pause put it:
  #
  #   * `SessionContinuation#abandon_or_retry_continue` — the sweeps' give-up,
  #     and the exact site whose `recovery_continue_abandoned` marker the second
  #     population carries.
  #   * `AgentSessionJob#auto_continue_after_interrupt` — the immediate
  #     continuation after an interrupt, which declines when there is no runtime
  #     session to resume. Without this the session waits out twelve doomed sweep
  #     attempts (about an hour) before reaching the give-up above, sitting in the
  #     action queue for all of it.
  #
  # ## Who picks the session up again
  #
  # Returning a session to `waiting` is only right if something reads `waiting`.
  # Two owners cover every shape this service will move, which is why the
  # conditions below are drawn where they are:
  #
  #   * `StalledSessionStart` (`StalledStartSweepJob`, every 5 minutes) restarts a
  #     `waiting` session with no runtime session id, a prompt, no dormant marker
  #     and no queued turn. `paused_by` is one of its dormant markers, so it is
  #     dropped here as part of the return.
  #   * `SpotHoldSweepJob` (every 5 minutes) re-arms the re-check ladder of a
  #     session the spot gate is holding. `SpotSessionHold.held?` requires
  #     `waiting`, so a held session parked in `needs_input` is invisible to it —
  #     which is precisely how the second population stopped being re-checked.
  #
  # ## The conditions, and why each one is load-bearing
  #
  #   1. **Resting in `needs_input`.** The only state this moves from; `sleep` is
  #      `needs_input → waiting`. Anywhere else there is nothing to correct.
  #   2. **No runtime session id.** The predicate every other recovery path uses
  #      for "has never run" (`AgentSessionJob#handle_interrupt_error` case 1,
  #      `StalledSessionStart` condition 1). A session that HAS a conversation
  #      behind it may genuinely be asking a human something.
  #   3. **The runtime wrote no conversation.** Asked of both stores through
  #      `RuntimeConversationPresence`, which answers "present" when it cannot
  #      tell. Condition 2 alone is not enough: a runtime that mints its own id
  #      (Codex) can have written a whole turn while Zimmer's `session_id` is
  #      still blank, and re-queueing that session would run its prompt a second
  #      time.
  #   4. **A prompt to run.** The same carve-out `StalledSessionStart` makes: a
  #      prompt-less session is one waiting for a human to send it something, so
  #      returning it to `waiting` would take it off the action queue and give
  #      nothing back — no sweep would start it either.
  #   5. **Not in a frozen category.** A parked bucket every bulk flow leaves
  #      alone.
  #   6. **No wake of its own armed.** `StalledSessionStart` partitions a session
  #      with a pending one-time wake out of its batch, and that disqualifier is
  #      not a metadata marker, so the return cannot drop it — a session moved
  #      with one armed would be read by neither owner. A session with its own
  #      next event has a way back anyway; there is nothing here to correct.
  #   7. **Budget left.** See MAX_RETURNS.
  class ReturnToQueue
    # How many times one session may be sent back to the queue before Zimmer
    # stops doing it and lets the session rest in `needs_input` after all.
    #
    # The bound is the point. `MAX_INTERRUPTED_START_REQUEUES` exists because a
    # start that cannot survive will re-queue forever, and this is the same
    # hazard one level up: a session that keeps reaching a give-up, being
    # returned to `waiting`, being re-dispatched and reaching the give-up again
    # would loop for as long as the deployment stays broken. Small on purpose —
    # each return costs a full dispatch attempt, and by the fifth the honest
    # answer is that a human should look.
    MAX_RETURNS = 5

    # How many times this session has been returned to the queue. Deliberately
    # NOT in Session::STALE_RETRY_METADATA_KEYS: a successful resume clears that
    # set, and a session that resumes for one second and dies again would get its
    # whole budget back every cycle — which is the loop the budget exists to
    # bound.
    COUNT_KEY = "unstarted_requeue_count"

    # Why the last return happened, so a reader can tell a session Zimmer
    # re-queued from one that has simply not been dispatched yet.
    REASON_KEY = "unstarted_requeue_reason"

    # Recorded when the budget runs out, so the `needs_input` the session then
    # rests in is legible as a decision rather than as the silent park this
    # service exists to remove.
    EXHAUSTED_KEY = "unstarted_requeue_exhausted"

    Result = Struct.new(:outcome, :message, keyword_init: true) do
      # The session is back in `waiting` and a sweep will re-dispatch it.
      def returned? = outcome == :returned

      # The budget is spent. The session rests in `needs_input` after all.
      def exhausted? = outcome == :exhausted

      # Not this service's case — the caller's own handling applies unchanged.
      def declined? = outcome == :declined
    end

    # @param session [Session]
    # @param reason [String] why Zimmer gave up, recorded on the session
    # @return [Result]
    def self.call(session, reason:)
      new(session, reason: reason).call
    end

    def initialize(session, reason:)
      @session = session
      @reason = reason
    end

    # @return [Result]
    def call
      session.reload
      refusal = refusal_reason
      return declined(refusal) if refusal

      count = (session.metadata || {})[COUNT_KEY].to_i + 1
      return exhaust(count - 1) if count > MAX_RETURNS

      return_to_queue!(count)
    rescue => e
      # A repair that cannot run must not become the thing that breaks the
      # give-up path it is called from. Decline, so the caller comes to rest
      # exactly as it did before this service existed.
      #
      # The reload is part of that promise, not tidying. #return_to_queue!'s
      # transaction rolls the ROW back but leaves the in-memory copy carrying the
      # writes it made, so a caller reading `session.metadata` next would see a
      # `paused_by` that is still on the row as absent — and act on it.
      Rails.logger.error(
        "[Sessions::ReturnToQueue] Could not return session #{@session&.id} to the queue: #{e.message}"
      )
      begin
        @session&.reload
      rescue => reload_error
        Rails.logger.error(
          "[Sessions::ReturnToQueue] Could not re-read session #{@session&.id} after a failed return: " \
          "#{reload_error.message}"
        )
      end
      declined(e.message)
    end

    private

    attr_reader :session, :reason

    # @return [String, nil] why this session is not ours to move
    def refusal_reason
      return "not resting in needs_input (#{session.status})" unless session.needs_input? && session.may_sleep?
      return "the session has a runtime session id" if session.session_id.present?
      return "no prompt to run" if session.prompt.blank?
      return "category is frozen" if session.category&.is_frozen?
      return "a wake of its own is armed" if session.awaiting_scheduled_wake?
      return "the runtime wrote a conversation" if conversation_persisted?

      nil
    end

    def conversation_persisted?
      RuntimeConversationPresence.persisted?(
        session: session,
        working_directory: session.metadata&.dig("working_directory")
      )
    end

    def return_to_queue!(count)
      # ONE transaction around the metadata write and the transition, because
      # dropping `paused_by` is only safe if the move actually happens. The row
      # can change under us between #refusal_reason and here — a human follow-up,
      # a queued-message drain landing at its delay, an archive — so `sleep!` can
      # raise, and #call answers that by declining and leaving the caller's own
      # handling to run. A committed metadata write would make that decline a
      # lie: the session would be `needs_input` with no `paused_by`, which neither
      # recovery sweep selects (they match the marker) and no start path reads
      # (they match `waiting`) — the exact dead end this service exists to remove,
      # reintroduced on its own failure path.
      #
      # `paused_by` goes with the move because it is the marker both recovery
      # sweeps select on AND one of StalledSessionStart's dormant markers, so
      # leaving it behind would hand the session straight back to the sweeps that
      # just gave up on it, and hide it from the sweep that can actually start it.
      ActiveRecord::Base.transaction do
        session.merge_metadata!(
          { COUNT_KEY => count, REASON_KEY => reason },
          [ "paused_by" ]
        )
        session.sleep!
      end

      session.logs.create!(
        content: "This session never ran — #{reason}. Returning it to the queue (attempt #{count} of " \
                 "#{MAX_RETURNS}) instead of leaving it in the action queue with nothing to ask; it will " \
                 "be started again when compute is available.",
        level: "info"
      )
      Rails.logger.info(
        "[Sessions::ReturnToQueue] Session #{session.id} returned to waiting (attempt #{count}/#{MAX_RETURNS}): #{reason}"
      )
      Result.new(outcome: :returned, message: "returned to the queue (attempt #{count})")
    end

    def exhaust(spent)
      message = "#{spent} return(s) to the queue did not get this session started"
      session.merge_metadata!(EXHAUSTED_KEY => message)
      session.logs.create!(
        content: "Not returning this session to the queue again: #{message}. It is coming to rest with " \
                 "an empty transcript — restart it by hand to try once more.",
        level: "error"
      )
      Rails.logger.warn("[Sessions::ReturnToQueue] Session #{session.id} exhausted its returns: #{message}")
      Result.new(outcome: :exhausted, message: message)
    end

    def declined(message)
      Result.new(outcome: :declined, message: message)
    end
  end
end
