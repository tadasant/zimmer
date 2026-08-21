# frozen_string_literal: true

# Pauses spot sessions that are ALREADY RUNNING when a quota window reaches its
# target, and resumes them once it has come back down.
#
# == Why the admission gate was not enough
#
# SpotSessionHold answers "should this work begin at all", once, at the starting
# line. That makes the target a floor under when new spot work stops, not a
# ceiling on what spot work spends: the sessions admitted just under the line go
# on running, and a fleet of them carries the window well past it. On 2026-08-20
# the /quotas card read "Holding spot sessions: 5-hour window at 89% of its 80%
# target" while twelve sessions ran — the gate had stopped admitting at 80% and
# then watched the ones already in flight take the pool toward 100%, with three
# accounts already `quota_exceeded`.
#
# So the same decision is re-evaluated while sessions are in flight.
# SpotCeilingSweepJob calls .sweep! on a cron; when SpotGateService says a
# window is at its target, every RUNNING spot session is paused.
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
# oldest-pause-first with the recovery nudge, so an interrupted agent is told to
# pick up where it left off.
#
# Resumption uses SpotGateService.resume_decision, which lowers both targets by
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

  METADATA_KEYS = [ PAUSED_AT, PAUSED_REASON, PAUSED_DETAIL, PAUSED_COUNT ].freeze

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
    # One pass: pause running spot sessions if a window is at its target,
    # otherwise resume the ones a previous pass paused.
    #
    # Never raises. This runs on a cron alongside everything else on the
    # `default` queue, and a spot-policy sweep that blew up would take its
    # retries with it — the condition it acts on is re-read from scratch every
    # five minutes anyway, so a failed pass costs one pass.
    #
    # @return [Result]
    def sweep!(logger: nil)
      logger ||= StructuredLogger.new({ service: "SpotSessionPause" })
      decision = SpotGateService.evaluate

      if decision.held? && decision.reason == UTILIZATION_REASON
        Result.new(paused: pause_running!(decision, logger), resumed: 0, held: 0)
      else
        resume_paused!(logger)
      end
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

    # Sessions currently dormant because of this service, oldest pause first —
    # so MAX_RESUMES_PER_SWEEP resumes the session that has been asleep longest
    # rather than whichever ids happen to sort lowest, sweep after sweep.
    # Ordered lexicographically over the stored string, which is why #pause!
    # writes it in UTC.
    def paused_sessions
      Session
        .where(status: :waiting)
        .where("metadata->>? IS NOT NULL", PAUSED_REASON)
        .order(Arel.sql("metadata->>'spot_pause_at' ASC NULLS FIRST"))
    end

    # Whether this session is dormant because the spot ceiling paused it.
    def paused?(session)
      session.waiting? && session.metadata&.dig(PAUSED_REASON).present?
    end

    # How many sessions are paused for the ceiling right now — the number
    # /quotas and `get_spot_policy` report, so both surfaces can say that
    # holding spot sessions stopped running ones too.
    def paused_count
      paused_sessions.count
    rescue ActiveRecord::ActiveRecordError
      0
    end

    private

    def pause_running!(decision, logger)
      sessions = pausable_sessions.to_a
      return 0 if sessions.empty?

      logger.info("A window reached its target — pausing running spot sessions",
        candidates: sessions.size, reason: decision.reason, detail: decision.detail)

      sessions.count { |session| pause!(session, decision, logger) }
    end

    # Pause one running spot session.
    #
    # The process is terminated BEFORE the status flips, for the reason
    # SessionsController#pause gives: flipping first makes AgentSessionJob's
    # monitoring loop exit on the status change without a final transcript poll,
    # losing the agent's last message. Killing first means the job sees the exit,
    # polls, and stops.
    def pause!(session, decision, logger)
      return false unless session.running?

      terminate_process(session, logger)

      paused = false
      ActiveRecord::Base.transaction do
        session.lock!
        raise ActiveRecord::Rollback unless session.running? && session.may_pause?

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

    def resume_paused!(logger)
      paused = paused_sessions.to_a
      return Result.new(paused: 0, resumed: 0, held: 0) if paused.empty?

      # A session someone made priority while it slept is not spot work any
      # more, and priority work is never gated on quota — so it goes back
      # whatever the windows say, and does not spend the batch below. This is
      # what the "Make this session priority" button on the pause banner does
      # for a session the ceiling has already stopped.
      promoted, still_spot = paused.partition { |session| !session.spot? }
      resumed = promoted.count { |session| resume!(session, promoted_message, logger) }

      return Result.new(paused: 0, resumed: resumed, held: 0) if still_spot.empty?

      decision = SpotGateService.resume_decision
      unless decision.allowed?
        logger.info("Spot-paused sessions stay asleep",
          asleep: still_spot.size, reason: decision.reason, detail: decision.detail)
        return Result.new(paused: 0, resumed: resumed, held: still_spot.size)
      end

      budget = [ resume_budget(decision), still_spot.size ].min
      resumed += still_spot.first(budget).count { |session| resume!(session, resume_message(decision), logger) }
      held = paused.size - resumed

      # Named rather than left implicit: a sweep that resumed 5 of 40 must not
      # read as "5 were waiting".
      if resumed.positive? || held.positive?
        logger.info("Resumed spot sessions the ceiling had paused",
          resumed: resumed, still_asleep: held, budget: budget)
      end

      Result.new(paused: 0, resumed: resumed, held: held)
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

      ActiveRecord::Base.transaction do
        session.lock!
        raise ActiveRecord::Rollback unless paused?(session) && session.may_resume?

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
      AgentSessionJob.enqueue_with_prompt(
        session.id,
        AutomatedPrompts.system_recovery(reason: resume_prompt_reason)
      )
      logger.info("Resumed a spot session the ceiling had paused", session_id: session.id)
      true
    rescue StandardError => e
      logger.warn("Could not resume a spot session the ceiling had paused",
        session_id: session.id, error: "#{e.class}: #{e.message}")
      false
    end

    def pause_message(decision)
      "Spot session paused mid-run: #{decision.detail} " \
        "Running spot sessions are paused at the target, not just new ones, so the window stops " \
        "climbing rather than filling to 100%. This session is dormant (waiting) and resumes " \
        "automatically once utilization falls #{SpotGateService::RESUME_MARGIN_PCT} points below " \
        "the target. Nothing is cancelled. Make it priority and the next sweep resumes it regardless."
    end

    def resume_message(decision)
      "Utilization came back down to #{decision.reason == "within_limits" ? "within the resume margin" : decision.reason} — " \
        "resuming this spot session automatically."
    end

    def promoted_message
      "This session is priority now, and priority work is never gated on quota — resuming it."
    end

    def resume_prompt_reason
      "Zimmer paused this spot session mid-run because a Claude Code quota window had reached " \
        "its target, and utilization has since come back down"
    end
  end
end
