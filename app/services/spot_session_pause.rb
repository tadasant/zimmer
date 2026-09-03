# frozen_string_literal: true

# Pauses spot sessions that are ALREADY RUNNING when a quota window's
# non-reserved budget is spent, and resumes them once it has room again.
#
# == Why the admission gate was not enough
#
# SpotSessionHold answers "should this work begin at all", once, at the starting
# line. That makes the budget a floor under when new spot work stops, not a
# ceiling on what spot work spends: the sessions admitted just under the line go
# on running, and a fleet of them carries the window well past it. On 2026-08-20
# the /quotas card read "Holding spot sessions: 5-hour window at 89% of its 80%
# target" while twelve sessions ran — the gate had stopped admitting and
# then watched the ones already in flight take the pool toward 100%, with three
# accounts already `quota_exceeded`.
#
# So the same decision is re-evaluated while sessions are in flight.
# SpotCeilingSweepJob calls .sweep! on a cron; when SpotGateService says a
# window's spot budget is spent, every RUNNING spot session is paused.
#
# Only the budget, never the pacing curve. A fleet merely ahead of the curve is
# throttled at the door — see SpotGateService::Reading#stops_running_work? for
# why interrupting a turn to enforce a curve protects nothing.
#
# == What a pause is
#
# The session's process is terminated and the session goes dormant in `waiting`
# — the same shape a `wake_me_up_later` sleep leaves behind, reached the same
# way: `pending_sleep` is set before `pause!`, and the pause callback's
# `execute_pending_sleep` carries it needs_input -> waiting.
#
# `waiting` rather than `needs_input` is the whole point. A session parked in
# needs_input lands on the operator's homepage action queue, which is for things
# a human must act on — and a quota pause is not one. Ten of them at once would
# bury the sessions that genuinely need a person.
#
# == Resumption
#
# The promise the spot model makes is that spot work is DEFERRED, never
# cancelled, and a pause with no way back would break it. The same sweep resumes
# them: when the gate allows spot work again, paused sessions are resumed
# highest-precedence-first with the recovery nudge, so an interrupted agent is
# told to pick up where it left off.
#
# Resumption uses SpotGateService.resume_decision, which widens both reserves by
# RESUME_MARGIN_PCT. Without that margin a session resumed at 79.9% pushes the
# window back over 80% within minutes and the next sweep pauses it again — a
# flap that costs a lost turn each way. It also inherits the fleet cap for free:
# a decision of `fleet_at_cap` resumes nobody, so paused work never crowds out
# the running fleet.
#
# == What it costs, and what is recorded
#
# Pausing interrupts a turn mid-flight. Whatever the agent had written to disk
# stays written; the tool call in flight is lost, and so is the reasoning that
# had not been flushed to the transcript. That is a real cost, paid once per
# pause, against a window that would otherwise run to 100% and take every
# account down with it.
#
# Because it is a real cost, it is legible rather than silent: the session
# carries `spot_pause_*` metadata (why, when, and the gate's own sentence), its
# log carries a line saying so, the session page renders a banner, and
# `paused_by` says `spot_quota` — so a reader can tell this apart from a turn
# that ended, a deployment restart, and a human hitting Pause.
#
# == A session can join the queue on purpose
#
# `action_session`'s "pause_into_spot_queue" (Sessions::PauseIntoSpotQueue) parks
# a session here deliberately: same `waiting`, same metadata, same resume sweep —
# no wake trigger and no wall clock. It carries QUEUED_REASON rather than a gate
# reason, so every surface
# that explains a dormant session can say which of the two happened to it, and
# so the ceiling's own cost is not overstated by counting it.
#
# == Priority sessions are never touched
#
# Only sessions that resolve to `spot` are eligible, and only on the Claude Code
# runtime — a Codex session spends nothing against a Claude window. Status
# summary forks are excluded too: they are Zimmer's own bookkeeping, they last
# seconds, and pausing one strands the blurb it exists to write.
class SpotSessionPause
  # Metadata keys written by a pause, cleared by the resume.
  PAUSED_AT = "spot_pause_at"
  PAUSED_REASON = "spot_pause_reason"
  PAUSED_DETAIL = "spot_pause_detail"
  PAUSED_COUNT = "spot_pause_count"

  # The resume prompt left with a deliberate park into the spot queue. Nothing
  # else carries it: a time-based pause hangs its prompt on the trigger it arms,
  # and the spot queue arms nothing.
  QUEUED_PROMPT = "spot_queue_prompt"

  METADATA_KEYS = [ PAUSED_AT, PAUSED_REASON, PAUSED_DETAIL, PAUSED_COUNT, QUEUED_PROMPT ].freeze

  # `spot_pause_reason` when the session was put here deliberately
  # (Sessions::PauseIntoSpotQueue) rather than the ceiling interrupting it. The dormancy and the resume path are identical — the same
  # sweep picks it up on the same gate decision — so it shares every key above;
  # only the wording differs, and it must, because "paused mid-run because a
  # quota window ran out of spot budget" is not what happened to this one.
  QUEUED_REASON = "user_spot_queue"

  # What `paused_by` says. Deliberately neither "user" (which would stop the
  # recovery sweeps auto-continuing it) nor "recovery" (which would make
  # DeploymentRecoveryJob adopt it and resume it into the very window this
  # service paused it for).
  PAUSED_BY = "spot_quota"

  # The one gate reason this service acts on. `fleet_at_cap` is not it: a
  # running session already holds its slot, so pausing it to free that slot for
  # another spot session would be work for nothing.
  UTILIZATION_REASON = SpotSessionHold::UTILIZATION_REASON

  # How many paused sessions one sweep may resume.
  #
  # The fleet cap already bounds the total, but a window that has just fallen
  # below its resume line is at its most fragile: every session resumed starts
  # spending again immediately. A batch, re-decided from a fresh reading five
  # minutes later, walks the fleet back up instead of restoring it all at once
  # and bouncing straight off the ceiling.
  MAX_RESUMES_PER_SWEEP = 5

  Result = Data.define(:paused, :resumed, :held) do
    def to_h = { paused: paused, resumed: resumed, held: held }
  end

  class << self
    # One pass: pause running spot sessions if a window's spot budget is spent,
    # otherwise resume the ones a previous pass paused.
    #
    # A session someone made priority while it slept is resumed on EVERY pass,
    # including one that is pausing everything else. It is not spot work any
    # more, and priority work is never gated on quota — so leaving it asleep
    # until utilization fell would break the promise the pause banner's "Make
    # this session priority" button makes, at exactly the moment somebody
    # pressed it.
    #
    # Never raises. This runs on a cron alongside everything else on the
    # `default` queue, and a spot-policy sweep that blew up would take its
    # retries with it — the condition it acts on is re-read from scratch every
    # five minutes anyway, so a failed pass costs one pass.
    #
    # @return [Result]
    def sweep!(logger: nil)
      logger ||= StructuredLogger.new({ service: "SpotSessionPause" })
      # The FLEET's decision, not an admission decision: this sweep asks whether
      # what is already running is over the line, so it must not have a
      # hypothetical extra session's burn added to the projection. See
      # SpotGateService.fleet_decision.
      decision = SpotGateService.fleet_decision

      # One read of the dormant population, and one read of the class overrides
      # it is classified against, for the whole pass.
      overrides = AppSetting.current.genesis_class_overrides

      # A session someone paused until a chosen time is off the table for this
      # sweep entirely — before the promotion branch, because promotion is the one
      # resume that happens on EVERY pass regardless of the gate, and a pause
      # outranks scheduling class just as it outranks precedence. These sessions
      # are counted as held rather than dropped: a sweep that left 3 of 8 asleep
      # for a reason must not report having looked at 5.
      dormant, sleeping_on_a_wake = split_paused_until(paused_sessions.to_a, logger)

      promoted, still_spot = dormant.partition { |session| !session.spot?(overrides) }
      resumed = promoted.count { |session| resume!(session, promoted_message, logger) }

      # Only a SPENT BUDGET stops running work — never a fleet that is merely
      # ahead of the pacing curve. The cap protects the priority reserve, which
      # is worth interrupting a turn for; the pace decides how fast new work is
      # released, and killing a running turn to enforce it would spend a lost
      # tool call protecting nothing. It is also what keeps the idle-fleet waiver
      # coherent: without this the sweep would pause the very session the waiver
      # had just admitted, and the two would flap. See
      # SpotGateService::Reading#stops_running_work?.
      if decision.stops_running_work?
        # `held` counts the sessions that were already asleep and stay that way,
        # not the ones this pass is putting to sleep — those are `paused`.
        return Result.new(paused: pause_running!(decision, overrides, logger),
                          resumed: resumed, held: still_spot.size + sleeping_on_a_wake)
      end

      resumed_spot, held = resume_spot!(still_spot, logger)

      Result.new(paused: 0, resumed: resumed + resumed_spot, held: held + sleeping_on_a_wake)
    rescue StandardError => e
      logger.warn("Spot ceiling sweep failed", error: "#{e.class}: #{e.message}")
      Result.new(paused: 0, resumed: 0, held: 0)
    end

    # Running spot sessions this service may pause, oldest first.
    def pausable_sessions
      Session.spot
        .where(status: :running, agent_runtime: ClaudeAuthProvider::RUNTIME)
        .excluding_status_summary_forks
        .order(:id)
    end

    # Sessions currently dormant in the spot queue, oldest pause first. The order
    # that decides which of them RUNS is #rank's, applied where the batch is
    # taken; this one is the stable read of the population.
    #
    # Ordered lexicographically over the stored string, which is why #pause!
    # writes it in UTC.
    def paused_sessions
      Session
        .where(status: :waiting)
        .where("metadata->>? IS NOT NULL", PAUSED_REASON)
        .order(Arel.sql("metadata->>'spot_pause_at' ASC NULLS FIRST"))
    end

    # Whether this session is dormant in the spot queue — paused mid-run by the
    # ceiling, or parked here deliberately. Both wait on the same gate and both
    # are resumed by the same sweep.
    def paused?(session)
      session.waiting? && session.metadata&.dig(PAUSED_REASON).present?
    end

    # Whether this session was parked in the queue on request rather than by the
    # ceiling.
    def queued_by_user?(session)
      session.metadata&.dig(PAUSED_REASON) == QUEUED_REASON
    end

    # Resume one dormant session on demand, rather than on the sweep's next pass.
    #
    # This is the door Sessions::StartNow comes through when a human presses
    # Start on a session the ceiling paused, or one parked here deliberately. It
    # is deliberately the SAME resume the sweep performs — the row lock, the
    # re-check under it, the prompt left with the park — because a
    # session put back by hand and one put back by the sweep must come back the
    # same way. What differs is only the sentence in its log.
    #
    # @return [Boolean] whether the session was resumed
    def resume_now!(session, actor: "a user", logger: nil)
      logger ||= StructuredLogger.new({ service: "SpotSessionPause" })
      resume!(session, "Resumed from the spot queue by #{actor}, ahead of the sweep.", logger)
    end

    # Split the ceiling's sleepers into the ones this sweep may resume and a count
    # of the ones a human (or an agent, through `wake_me_up_later`) has paused
    # until a chosen time.
    #
    # One batched query for the whole set rather than one per session. An
    # unreadable trigger table raises out of here and #sweep!'s own rescue turns
    # the pass into a no-op, which is the safe direction: the sweep re-reads
    # everything from scratch five minutes later, and a pass that resumed nothing
    # costs a pass, while a pass that trampled a pause costs the pause.
    #
    # @return [Array(Array<Session>, Integer)] resumable sessions, and how many were paused
    def split_paused_until(sessions, logger)
      return [ sessions, 0 ] if sessions.empty?

      sleeping = Session.ids_paused_until_scheduled_time(sessions.map(&:id))
      return [ sessions, 0 ] if sleeping.empty?

      resumable = sessions.reject { |session| sleeping.include?(session.id) }
      logger.info("Left spot sessions asleep on their own wake-ups",
        paused_until: sessions.size - resumable.size)

      [ resumable, sessions.size - resumable.size ]
    end

    # The standing population of sessions the ceiling has stopped and not yet put
    # back — the number /quotas and `get_spot_policy` report.
    #
    # Three things it is NOT, each of which it has been misread as:
    #
    # - Not a count of RUNNING sessions. Every one of these is dormant in
    #   `waiting`. It is therefore unrelated to `spot_max_concurrent_sessions`
    #   and routinely larger than it — a backlog of 17 beside a fleet cap of 5 is
    #   the normal shape, not a contradiction.
    # - Not a cumulative tally. It is a live `COUNT` over the queue, so it falls
    #   as the sweep resumes sessions.
    # - Not "paused in this instant". These were paused at some point when a
    #   window's spot budget was spent; a fleet merely ahead of the pacing curve
    #   pauses nothing, so the backlog can sit here while nothing is being
    #   stopped. SpotHoldExplanation is what tells the two apart on the page.
    #
    # Deliberately NOT every dormant session in the queue: a session a human
    # parked there had its turn taken away by that human, not by the ceiling, and
    # counting it would attribute their decision to the quota gate.
    def paused_count
      paused_sessions.where.not("metadata->>? = ?", PAUSED_REASON, QUEUED_REASON).count
    rescue ActiveRecord::ActiveRecordError
      0
    end

    private

    def pause_running!(decision, overrides, logger)
      sessions = pausable_sessions.to_a
      return 0 if sessions.empty?

      logger.info("A window's spot budget is spent — pausing running spot sessions",
        candidates: sessions.size, reason: decision.reason, detail: decision.detail)

      sessions.count { |session| pause!(session, decision, overrides, logger) }
    end

    # Pause one running spot session.
    #
    # The process is terminated BEFORE the status flips, for the reason
    # SessionsController#pause gives: flipping first makes AgentSessionJob's
    # monitoring loop exit on the status change without a final transcript poll,
    # losing the agent's last message. Killing first means the job sees the exit,
    # polls, and stops.
    def pause!(session, decision, overrides, logger)
      return false unless session.running?
      # A session just parked into the queue is already on its way here: it
      # carries the queue record and is either asleep or sleeping at the end of
      # its turn. Pausing it again would overwrite its story with the ceiling's,
      # and the count below would charge a turn to the ceiling that the ceiling
      # never took. (A running session reaching here still carrying the queue
      # record is one parked without `halt`, so its own turn end will sleep it.)
      return false if queued_by_user?(session)

      terminate_process(session, logger)

      paused = false
      ActiveRecord::Base.transaction do
        session.lock!
        # The class is re-read under the lock, not just when the batch was
        # selected. A full-fleet pause spends seconds per session waiting out
        # SIGTERM grace, which is time enough for somebody to press "Make this
        # session priority" on one still queued behind it — and pausing a
        # priority session is the one thing this service must never do.
        raise ActiveRecord::Rollback unless session.running? && session.may_pause? && session.spot?(overrides)

        metadata = (session.metadata || {}).merge(
          PAUSED_AT => Time.current.utc.iso8601,
          PAUSED_REASON => decision.reason,
          PAUSED_DETAIL => decision.detail,
          PAUSED_COUNT => (session.metadata || {})[PAUSED_COUNT].to_i + 1,
          "paused_by" => PAUSED_BY,
          # What actually makes the session dormant: the pause callback reads
          # this and sleeps it needs_input -> waiting.
          "pending_sleep" => true
        )

        session.update!(running_job_id: nil, metadata: metadata)
        session.pause!
        paused = true
      end
      return false unless paused

      session.reload
      # Belt and braces. execute_pending_sleep swallows its own failures (it
      # alerts rather than raises), and a session left in needs_input would sit
      # in the operator's action queue asking for a decision nobody has to make.
      session.sleep! if session.needs_input? && session.may_sleep?

      session.logs.create!(level: "warning", content: pause_message(decision))
      logger.info("Paused a running spot session", session_id: session.id, reason: decision.reason)
      true
    rescue StandardError => e
      logger.warn("Could not pause running spot session",
        session_id: session.id, error: "#{e.class}: #{e.message}")
      false
    end

    # Kill the CLI process a running session owns. Best effort: a session whose
    # process has already gone still gets paused, which is the state the sweep
    # is trying to reach.
    def terminate_process(session, logger)
      pid = session.metadata&.dig("process_pid")
      return if pid.blank?

      manager = ProcessLifecycleManager.new(session: session, process_manager: SystemProcessManager.new)
      result = manager.resume_monitoring(pid: pid, stderr_log_path: session.stderr_log_path)
      return unless result.success?

      manager.terminate(reason: :spot_ceiling)
    rescue StandardError => e
      logger.warn("Could not terminate the process of a paused spot session",
        session_id: session.id, error: "#{e.class}: #{e.message}")
    end

    # Put back as many of the still-spot sleepers as the gate and the batch
    # allow, HIGHEST PRECEDENCE FIRST.
    #
    # The budget is smaller than the population this usually holds, so the order
    # decides which spot work runs when a window comes back down — which is the
    # same question the ranked queue exists to answer. Resuming by pause age
    # instead would hand the recovered headroom to whichever session happened to
    # be paused longest, ignoring the operator's ordering exactly where it is
    # meant to apply. Ties break on the oldest pause, so equal-ranked sessions
    # still take turns.
    #
    # @return [Array(Integer, Integer)] resumed, and left asleep
    def resume_spot!(sessions, logger)
      return [ 0, 0 ] if sessions.empty?

      sessions = rank(sessions)

      decision = SpotGateService.resume_decision
      unless decision.allowed?
        logger.info("Spot-paused sessions stay asleep",
          asleep: sessions.size, reason: decision.reason, detail: decision.detail)
        return [ 0, sessions.size ]
      end

      budget = [ resume_budget(decision), sessions.size ].min
      resumed = sessions.first(budget).count { |session| resume!(session, resume_message(decision, session), logger) }
      held = sessions.size - resumed

      # Named rather than left implicit: a sweep that resumed 5 of 40 must not
      # read as "5 were waiting".
      logger.info("Resumed spot sessions from the queue, highest precedence first",
        resumed: resumed, still_asleep: held, budget: budget)

      [ resumed, held ]
    end

    # Highest precedence first, oldest pause within a tie. Sorted in Ruby: the
    # caller has already loaded and partitioned the population, so re-querying it
    # to sort would cost a round trip for a list this size.
    def rank(sessions)
      sessions.sort_by do |session|
        [ -session.precedence.to_i, session.metadata&.dig(PAUSED_AT).to_s, session.id ]
      end
    end

    # How many sessions this sweep may put back. Bounded by the free slots the
    # decision counted, so resuming can never overshoot the fleet cap, and by
    # MAX_RESUMES_PER_SWEEP. A fail-open decision (gating off, no reading) has no
    # cap to read, and its answer is "spot work runs" — so the batch size alone
    # bounds it.
    def resume_budget(decision)
      return MAX_RESUMES_PER_SWEEP if decision.fleet_cap.nil?

      headroom = [ decision.fleet_cap - decision.active_sessions.to_i, 0 ].max

      [ headroom, MAX_RESUMES_PER_SWEEP ].min
    end

    # Resume one paused session: a row lock, a re-check under it, and one
    # transaction that drops the pause record before transitioning — the same
    # shape as every other automated resume in the app.
    #
    # `resume_for_system_recovery!` rather than `resume!`: this session did not
    # choose to stop, so the one-time wake-ups it had armed when the sweep
    # interrupted it are still exactly what it is waiting on. A plain resume
    # consumes them, which is how an orchestrator comes back with nothing armed
    # and strands the children it was watching.
    def resume!(session, message, logger)
      resumed = false
      # Read before the transaction clears it: a human who parked this session
      # into the queue may have left the prompt it should come back on.
      queued = queued_by_user?(session)
      requested_prompt = session.metadata&.dig(QUEUED_PROMPT).presence

      ActiveRecord::Base.transaction do
        session.lock!
        raise ActiveRecord::Rollback unless paused?(session) && session.may_resume?
        # Re-asked under the lock. #sweep! already filtered these out, but a pause
        # armed between that read and this one would otherwise be trampled by a
        # sweep that decided before it existed — and this method is the only door
        # into the resume, so closing it here closes it for every caller.
        raise ActiveRecord::Rollback if session.paused_until_scheduled_time?

        session.update!(
          running_job_id: nil,
          metadata: (session.metadata || {})
            .except(*METADATA_KEYS, "paused_by")
            .except(*Session::STALE_RETRY_METADATA_KEYS)
        )
        resumed = session.resume_for_system_recovery!
      end
      return false unless resumed && session.reload.running?

      session.logs.create!(level: "info", content: message)
      # A human queueing the session may have typed what it should come back on;
      # a ceiling pause has nobody to ask, so it gets the recovery nudge with the
      # reason that fits how it stopped.
      AgentSessionJob.enqueue_with_prompt(
        session.id,
        requested_prompt || AutomatedPrompts.system_recovery(reason: resume_prompt_reason(queued))
      )
      logger.info("Resumed a spot session from the queue", session_id: session.id, queued_by_user: queued)
      true
    rescue StandardError => e
      logger.warn("Could not resume a spot session from the queue",
        session_id: session.id, error: "#{e.class}: #{e.message}")
      false
    end

    def pause_message(decision)
      "Spot session paused mid-run: #{decision.detail} " \
        "Running spot sessions are paused when a window's non-reserved budget is spent, not just new " \
        "ones, so the window stops climbing rather than eating the reserve priority work is held out " \
        "of. This session is dormant (waiting) and resumes automatically once the fleet is back inside " \
        "the budget with #{SpotGateService::RESUME_MARGIN_PCT} points of the window to spare. Nothing " \
        "is cancelled. Make it priority and the next sweep resumes it regardless."
    end

    # Three sentences because a resume has three shapes: the window genuinely fell
    # (the common one), the gate stopped holding work for some other reason —
    # somebody turned gating off, or there is no reading to decide on — or the
    # session was never paused at all and was put in the queue deliberately.
    # Naming any of them as one of the others would be a lie in the log.
    def resume_message(decision, session)
      if queued_by_user?(session)
        "The spot queue reached this session (#{decision.reason}) — resuming it. " \
          "It was parked here deliberately, not paused by the ceiling."
      elsif decision.reason == "within_limits"
        "The window has room again past the resume margin — resuming this spot session automatically."
      else
        "The spot gate is no longer holding spot work (#{decision.reason}) — " \
          "resuming this spot session automatically."
      end
    end

    def promoted_message
      "This session is priority now, and priority work is never gated on quota — resuming it."
    end

    # What the resumed agent is told about why it is awake. A queued session was
    # never interrupted — it was parked deliberately — so telling it a quota
    # window had stopped it mid-turn would send it hunting for lost work
    # that was never lost. It does not name the gate reading either: the promoted
    # branch resumes a session whatever the windows say, and this sentence is
    # shared with it.
    def resume_prompt_reason(queued)
      if queued
        "this session was parked in Zimmer's spot queue with no wake-up time, " \
          "and Zimmer has now resumed it from that queue"
      else
        "Zimmer paused this spot session mid-run because a Claude Code quota window had spent the " \
          "part of itself that spot work may use, and it has room again"
      end
    end
  end
end
