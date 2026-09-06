# frozen_string_literal: true

module Sessions
  # Whether a session's conversation is LIVE right now — a turn an agent process
  # is executing, a turn on its way to one, or a prompt that has been accepted
  # for it and not yet delivered.
  #
  # THE DEFECT THIS EXISTS FOR (#400). Two agent processes ran against one
  # session's conversation at once. One had just been handed a new follow-up
  # prompt and was working on it; the other was a status-summary fork stood up
  # from the same conversation a second earlier, resumed into the runtime's own
  # `"Continue from where you left off."` scaffolding, holding 737 messages of
  # pre-archive context and no trace of the new prompt. From inside that context
  # "my work is done, archive" is a correct inference, so it archived the
  # session — and AgentSessionJob's monitoring loop, seeing `archived?`, killed
  # the live turn mid-tool-call and deleted its clone. 45 seconds from job start
  # to trash, at `info` level, with nothing distinguishing that from a session
  # that finished.
  #
  # Two callers ask this, for the two halves of that failure:
  #
  #   * SessionStatusSummaryGenerator, before standing a second agent up on a
  #     conversation — a fork of a conversation that has already moved on is a
  #     stale replay, and it answers from the transcript alone, so the cheap
  #     headless path loses nothing by taking it instead.
  #   * Mcp::Tools::ActionSession, before letting one session archive another —
  #     an archive over a turn in flight terminates that process and discards
  #     its work.
  #
  # This is the same question Session#claim_system_recovery_turn! answers for
  # the recovery sweeps ("is somebody else already driving this session?"),
  # asked by the callers that are not enqueueing a turn and so have nothing to
  # claim. It reads the same evidence: GoodJob rows, not `running_job_id`.
  # PendingAgentTurns documents why — `running_job_id` is written from INSIDE
  # `AgentSessionJob#perform`, so a turn still queued has a blank one and reads
  # as no turn at all.
  #
  # == This module is now the "a turn is already in flight" guard
  #
  # It used to be enough to ask `session.running?`. Since #1040 a turn that has
  # been handed over and is queued for one of the `agents` lane's worker threads
  # reads `waiting` — so `running?` answers "no turn" for a session that has one
  # coming, and every caller that used it to decide "do not start a second turn"
  # would start one. Those callers ask #underway? instead: the web, REST and MCP
  # follow-up routes, `Trigger#follow_up_session!`, `EnqueuedMessageDrainJob`,
  # `Sessions::MessageParent`, `Session#claim_system_recovery_turn!` and the
  # follow-up composer. The status gate below is correspondingly
  # `running? || waiting?` on every predicate here.
  module LiveTurn
    module_function

    # Is an agent process executing a turn on this session right now?
    #
    # The narrow reading, and the one an archive is refused on: a job row for
    # this session that `JobLiveness` calls `:running` — locked by a capsule
    # that is demonstrably alive. That, and not `performed_at` alone, is what
    # "a process would be killed by archiving this" means.
    #
    # `performed_at` alone would be WRONG here, even though it is exactly right
    # for RunningTurns' occupancy counts. A worker that was SIGKILLed, OOMed or
    # evicted leaves its row with `performed_at` set and `finished_at` null
    # forever — so a stuck session, which is precisely the one a fleet-repair
    # sweep archives, would read as a live turn and be refused. Nothing is
    # executing there and nothing is destroyed. `JobLiveness` is the existing
    # answer to "is anything still running this job", asked of the database
    # because Zimmer's `web` and `worker` roles are separate containers with
    # separate PID namespaces; AgentSessionJob's own concurrency guard asks it
    # the same way.
    #
    # A turn merely QUEUED is deliberately not in it either. Nothing is
    # executing, so archiving destroys nothing — it cancels a turn, which is
    # what the caller asked for. #coming? is the wider reading, for the caller
    # that cares whether the conversation is about to change rather than
    # whether a process dies.
    #
    # Fails CLOSED, unlike RunningTurns' counts: an unreadable `good_jobs` here
    # would otherwise let an archive through onto a turn it could not see, which
    # is the exact silent kill this guard exists to stop. A guard that refuses
    # too often is recoverable — the caller is told why and `force` is one call
    # away; a guard that lets the kill through is not.
    #
    # @param session [Session]
    # @return [Boolean]
    def in_flight?(session)
      return false unless session_may_hold_a_turn?(session)

      unfinished_turns(session).any? { |job| JobLiveness.status(job) == :running }
    rescue StandardError => e
      Rails.logger.warn("[Sessions::LiveTurn] Could not read the agents queue for session #{session&.id} " \
                        "(#{e.class}: #{e.message}) — treating the turn as in flight")
      true
    end

    # Is a turn underway for this session — on a worker thread right now, or
    # ready in the `agents` queue with a worker coming for it?
    #
    # THE GUARD `running?` USED TO BE. Every caller that has to decide "is a turn
    # already in flight, so hand this prompt to the queue rather than starting a
    # second one" asks this: the follow-up routes (web, REST, MCP), the wake and
    # poller deliveries in Trigger, EnqueuedMessageDrainJob's dormancy check, and
    # Sessions::MessageParent. Reading `session.running?` for that became wrong
    # the moment a queued turn started reading `waiting` (#1040).
    #
    # NARROWER than #coming? for a `waiting` session, and the difference is
    # deliberate. #coming? counts
    # `JobLiveness::LIVE_STATUSES`, which includes a job parked on a future
    # `scheduled_at` — a spot-gate re-check, a clone-retry backoff. Those are
    # turns that will run *later*, and a follow-up sent to a session in that state
    # is supposed to be DELIVERED, not queued behind a re-check that may be
    # minutes away. Only `:running` (a live worker holds it) and `:queued` (ready,
    # unclaimed, a worker will take it on its next poll) mean a turn is underway
    # now.
    #
    # A `clone_only` job is excluded, because it spends no turn: it makes the clone
    # and returns without spawning an agent and without draining the queue. Reading
    # it as a turn would send the first prompt into a cloning session to the queue,
    # where nothing at that job's end picks it up.
    #
    # Fails CLOSED, like #in_flight?: an unreadable `good_jobs` reads as "a turn
    # is underway", which routes the prompt into the durable queue. A queued
    # message drains at the next turn boundary; a second concurrent turn is #400.
    #
    # @param session [Session]
    # @return [Boolean]
    def underway?(session)
      return false unless session_may_hold_a_turn?(session)
      # A `running` row answers yes without a query, and that is deliberate
      # rather than an optimisation: it is exactly what `session.running?` used
      # to mean at these call sites, so keeping it makes this a pure WIDENING of
      # the old guard. A `running` session whose job row has gone is an orphan a
      # recovery sweep owns, and a follow-up into it should still queue behind the
      # turn the sweep is about to restart rather than race it.
      return true if session.running?

      unfinished_turns(session).reject { |job| AgentJobIntent.clone_only?(job) }
        .any? { |job| UNDERWAY_STATUSES.include?(JobLiveness.status(job)) }
    rescue StandardError => e
      Rails.logger.warn("[Sessions::LiveTurn] Could not read the agents queue for session #{session&.id} " \
                        "(#{e.class}: #{e.message}) — treating a turn as underway")
      true
    end

    # The statuses in which a worker either has this turn or is about to.
    #
    # `:abandoned` is in here and `:scheduled` is not, and the asymmetry is the
    # point. `JobLiveness` calls a ready, unclaimed job `:abandoned` once it is
    # older than ABANDONED_QUEUED_JOB_AGE — a horizon its own comment calls
    # "deliberately far longer than any plausible queue delay", which was true
    # when only a wedged job could reach it. Since #1040 the queue behind an
    # 8-thread pool is a real population that a busy deployment holds for minutes,
    # and a turn that has waited 31 of them is still a turn a worker will run. Its
    # absence here would open EVERY guard at once, at exactly the moment the queue
    # is deepest. A `:scheduled` job is different in kind rather than in age: it is
    # parked to a future time by an owner that is not the worker pool.
    UNDERWAY_STATUSES = %i[running queued abandoned].freeze

    # The cheap status gate every predicate here takes before touching
    # `good_jobs`.
    #
    # `running` and `waiting` are the two states a session with a turn can be in
    # since #1040: `running` once a worker has spawned its process, `waiting`
    # while the turn sits in the `agents` queue. `needs_input`, `failed` and
    # `archived` are rest states — a job row against one of those is a corpse or
    # a race the callers here deliberately do not act on.
    #
    # @param session [Session, nil]
    # @return [Boolean]
    def session_may_hold_a_turn?(session)
      return false if session.nil?

      session.running? || session.waiting?
    end

    # This session's unfinished AgentSessionJob rows.
    #
    # Read the same way PendingAgentTurns reads them — off
    # `serialized_params -> 'arguments' ->> 0`, the session id every one of
    # AgentSessionJob's enqueue helpers passes first — rather than off
    # `sessions.running_job_id`, which is written from INSIDE `perform` and so is
    # blank for a turn a worker has not started.
    #
    # @param session [Session]
    # @return [Array<GoodJob::Job>]
    def unfinished_turns(session)
      GoodJob::Job
        .where(job_class: AgentSessionJob.name, finished_at: nil)
        .where("serialized_params -> 'arguments' ->> 0 = ?", session.id.to_s)
        .to_a
    end

    # Has a prompt been accepted for this session that it has not seen yet?
    #
    # Both markers, because they are written by different halves of the delivery
    # path and either one alone leaves a window: `EnqueuedMessage` is the durable
    # queue, and `pending_follow_up_prompt` is stamped for a prompt already handed
    # to a job by every route that accepts a follow-up into an idle session
    # (`Session#deliver_follow_up!`, `Mcp::Tools::ActionSession#direct_follow_up`,
    # `Api::V1::SessionsController#follow_up`). A conversation with either is one
    # whose next turn is already decided.
    #
    # Only where that next turn can actually happen, which is what the status
    # check is for. Neither marker is cleaned up on the way into a terminal
    # state: ArchiveGuard's own comment records that nothing drains the queue of
    # a session that will not run again, and AuthOutageParkService leaves
    # `pending_follow_up_prompt` standing. Without the guard a `failed` session
    # holding a stranded message would read as live forever and never be given a
    # fork again — a permanent downgrade, out of a signal that is supposed to be
    # about a conversation in motion.
    #
    # @param session [Session]
    # @return [Boolean]
    def undelivered_prompt?(session)
      return false if session.nil?
      return false if session.archived? || session.failed?

      session.enqueued_messages.pending.exists? ||
        session.metadata&.dig("pending_follow_up_prompt").present?
    end

    # Is a turn executing, or still going to be?
    #
    # The wider reading of #in_flight?, for a caller deciding whether the
    # conversation is about to change rather than whether a process would die.
    # `JobLiveness::LIVE_STATUSES` is the whole difference: it adds the turn
    # queued for a worker and the one parked on a retry backoff, and it excludes
    # the same corpses #in_flight? excludes — a job whose worker is gone is not
    # a turn that is coming.
    #
    # @param session [Session]
    # @return [Boolean]
    def coming?(session)
      return false unless session_may_hold_a_turn?(session)

      unfinished_turns(session).any? { |job| JobLiveness.alive?(job) }
    rescue StandardError => e
      Rails.logger.warn("[Sessions::LiveTurn] Could not read the agents queue for session #{session&.id} " \
                        "(#{e.class}: #{e.message}) — treating a turn as coming")
      true
    end

    # Why this conversation counts as live — nil when it does not.
    #
    # The question a caller about to snapshot the conversation asks, and the
    # reason it gets is what it logs. A snapshot taken while any of these hold
    # is stale before the agent reading it has finished its first sentence.
    #
    # `coming?` subsumes `in_flight?`, so only the narrower phrase is used when
    # it applies rather than both.
    #
    # @param session [Session]
    # @return [String, nil]
    def describe(session)
      reasons = [ turn_phrase(session) ]
      reasons << "a prompt has been accepted for it and not yet delivered" if undelivered_prompt?(session)

      reasons.compact.presence&.join(", and ")
    end

    # How this session's turn counts as live, or nil if none does.
    #
    # One read of the job rows, classified twice, rather than asking #in_flight?
    # and then #coming? — which are the same query issued back to back. Fails
    # closed on the narrower phrase, for the reason #in_flight? does.
    #
    # @param session [Session]
    # @return [String, nil]
    def turn_phrase(session)
      return nil unless session_may_hold_a_turn?(session)

      turns = unfinished_turns(session)
      return "a turn is in flight on it" if turns.any? { |job| JobLiveness.status(job) == :running }
      return "a turn is queued for it" if turns.any? { |job| JobLiveness.alive?(job) }

      nil
    rescue StandardError => e
      Rails.logger.warn("[Sessions::LiveTurn] Could not read the agents queue for session #{session&.id} " \
                        "(#{e.class}: #{e.message}) — treating the turn as in flight")
      "a turn is in flight on it"
    end

    # The refusal an agent reads when it tries to archive somebody else's
    # running turn.
    #
    # Leads with what the archive would destroy, because the caller cannot see
    # it: from outside, a `running` session with a growing message count and an
    # `archived` one look like a session that finished. Names the alternatives
    # before `force`, for the same reason ArchiveGuard does — the caller that
    # hits this most is trying to redirect a session, and a follow-up does that
    # without throwing the turn away.
    #
    # @param session [Session]
    # @param batch [Boolean] whether the caller is archiving a batch, in which
    #   case `force` would apply to every session in it rather than this one
    # @return [String]
    def refusal_message(session, batch: false)
      [
        "Cannot archive session #{session.id}: an agent turn is in flight on it right now. " \
        "Archiving terminates that process mid-turn and deletes its clone, so whatever it has not " \
        "committed is lost — and nothing afterwards distinguishes that from a session that finished.",
        "",
        "You are not that session, so you cannot know what it is in the middle of. If you are trying to " \
        "redirect it, send it a \"follow_up\" instead (with \"force_immediate\": true to get ahead of the " \
        "turn it is in) — it keeps the conversation and the work. If you want it to stop, \"pause\" it and " \
        "archive once it has come to rest.",
        "",
        "Only if you have decided to destroy the running turn: re-call with \"force\": true." +
          (batch ? " On a batch archive that flag applies to every session in the batch, including ones " \
                   "whose running turns you have not been shown." : "")
      ].join("\n")
    end

    # The line written onto a session's own timeline when an archive was forced
    # over its running turn. The session cannot report this itself — it is being
    # killed — so the caller records it on the way past.
    #
    # @param actor [String] how the archive names whoever asked for it
    # @return [String]
    def forced_over_live_turn_log(actor)
      "Archived by #{actor} while an agent turn was in flight — the running process was terminated " \
      "mid-turn and its uncommitted work discarded. This was not the session finishing."
    end
  end
end
