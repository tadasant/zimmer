# frozen_string_literal: true

# Takes a session slot away from a running spot session so a priority session
# can have it, and gives it back when the fleet has room again.
#
# == What was missing
#
# "Max sessions at once" was checked when a session started and never again, so
# the crowding-out it promises was entirely PASSIVE. A priority session starting
# over the cap did not stop any spot session already running — it ran alongside,
# one over the ceiling, and starved the NEXT spot start instead. Ten priority
# sessions leaving zero spot slots was true only of sessions that had not begun
# yet; the spot work already in flight kept its slots and the fleet simply ran
# wider than the number the operator set.
#
# SpotSessionPause already does the active half of this for a quota window: when
# a window's non-reserved budget is spent it stops the spot sessions that are
# already running. This is the same move for the CONCURRENCY ceiling, and it is
# deliberately the same machinery — the victim lands in SpotSessionPause's queue,
# carrying SpotSessionPause::PREEMPTED_REASON, and that queue's existing sweep is
# what puts it back.
#
# == One resume owner, and it is not this class
#
# This class never resumes anything, and that is the single most important thing
# about it. A dormant spot session with two owners is tadasant/zimmer#617 — two
# sweeps that can each decide to start the same session, neither knowing the
# other stopped it. So preemption writes a record SpotSessionPause already owns
# and stops there. Its resume condition is already exactly right: a paused spot
# session comes back when the gate allows spot work AND `resume_budget` finds a
# free slot under the cap. A slot freed by the priority session finishing is
# precisely the headroom that releases it, in the queue's own precedence order.
#
# == It marks, and the turn ends on its own
#
# A preemption does NOT kill the victim's process on the spot. The priority
# session is never held by the cap and starts either way, so nothing is waiting
# on the slot in the sense that a lock is waiting: what is at stake is the fleet
# converging back to the size the operator asked for, and paying a lost tool
# call plus unflushed reasoning to make that happen four minutes sooner is a bad
# trade. So the victim is MARKED — the pause record and `pending_sleep` are
# written while it runs — and its own turn end carries it needs_input -> waiting
# through the same `execute_pending_sleep` a deliberate park uses.
#
# The mark is not a promise that costs nothing, though, so it is bounded on both
# sides by #sweep!, which runs on SpotCeilingSweepJob's five-minute cron:
#
#   * **The slot came back on its own.** The priority session finished, or
#     something else ended, and the fleet is under its cap again while the
#     victim is still running. Then the preemption was never needed: the mark is
#     RELEASED, the session keeps its turn, and nothing was lost at all. This is
#     the common case for a short priority session, and it is why marking rather
#     than halting is not merely gentler but usually free.
#   * **The turn is not ending.** The mark has stood longer than GRACE and the
#     fleet is still at or over its cap. Then the deferral has stopped being a
#     deferral, and the turn is halted where it stands
#     (Sessions::HaltRunningTurn) — the same cost SpotSessionPause pays, paid
#     only by the sessions whose turns would otherwise have made the ceiling
#     mean nothing.
#
# == Choosing who yields
#
# The spot queue's own ordering, read backwards. `precedence` is the operator's
# instrument for saying which spot work matters, and the sweep that RESUMES this
# queue takes the highest first — so the one that yields is the lowest. Anything
# else would mean the queue decided who runs and something else decided who
# stops, which are the same decision.
#
# Ties on precedence are the normal case (the default is 0 for everyone nobody
# has ranked), so three more keys break them, in this order:
#
#   1. **Fewest prior preemptions.** The durable ledger below. Spreads the cost
#      across the fleet instead of charging it to whichever session happens to
#      sort first every time.
#   2. **Least human involvement**, counted exactly as
#      Sessions::HumanInterventionPromotion counts it — HumanMessage rows on the
#      session itself. A session a person is in the middle of a conversation
#      with is the last one to have its turn taken away, and the two halves of
#      this feature measure "involvement" the same way on purpose.
#   3. **Newest first.** Among sessions that are otherwise equal, the one that
#      has been running least long has least in flight to lose.
#
# == Thrash control
#
# Three separate bounds, because a steady stream of priority sessions is the
# case that breaks a naive implementation:
#
#   * **One victim per priority start.** Each priority session pays for exactly
#     the one slot it takes. Nothing here ever preempts a batch, so a fleet that
#     is several over its cap converges one start at a time rather than emptying
#     itself in one pass.
#   * **A cooldown.** A session preempted within COOLDOWN is not eligible again,
#     read off the DURABLE half of the ledger (LAST_AT and COUNT, which a resume
#     deliberately does NOT clear). Without it, a session resumed into a free
#     slot at 12:00 is the lowest-precedence running spot session again at 12:01
#     and yields again immediately — pause, resume, pause, forever, with a lost
#     turn on each cycle and no work done in between.
#   * **A session already carrying a pause record is never a candidate.** It is
#     on its way out of the fleet already; picking it again would spend a
#     preemption on a slot that was going to free anyway.
#
# When no candidate survives all of that, NOTHING is preempted and the fleet
# stays one over its cap — which is exactly what it did before this class
# existed. That is the fail-safe direction, and every error path in here lands
# on it.
class SpotPreemption
  # The DURABLE half of the preemption ledger. Deliberately not in
  # SpotSessionPause::METADATA_KEYS, so a resume does not clear them: the whole
  # point of both is to be readable on a session that has already come back, and
  # a counter reset by the resume would make the cooldown and the fairness key
  # below permanently read "never preempted".
  COUNT = "spot_preempt_count"
  LAST_AT = "spot_preempt_last_at"

  # How long after being preempted a session is off the table for another one.
  #
  # Sized against the resume path rather than against anything about turns: the
  # ceiling sweep runs every five minutes and resumes up to
  # SpotSessionPause::MAX_RESUMES_PER_SWEEP sessions per pass, so a session that
  # has just come back has to survive several passes' worth of priority starts
  # before it is fair game again. Thirty minutes is long enough for a resumed
  # session to have done something with its slot, and short enough that a small
  # fleet does not run out of eligible victims.
  COOLDOWN = 30.minutes

  # How long a marked session is given to end its own turn before the mark is
  # escalated to a halt.
  #
  # Two cron passes plus change. The sweep that acts on this runs every five
  # minutes, so anything under ten would escalate on the first pass after the
  # mark and make the graceful path meaningless; anything much over it leaves the
  # fleet over its cap for longer than the operator's number suggests.
  GRACE = 10.minutes

  # What a released mark says on the session's own timeline. The good outcome,
  # and worth a line: a reader who saw the mark go on has to be able to see it
  # come off, or the timeline reads as a preemption that silently did nothing.
  RELEASED_MESSAGE =
    "The fleet fell back under its concurrency limit before this turn ended, so the preemption was " \
    "not needed after all. The mark is dropped, nothing was lost, and this session carries on."

  # The expensive outcome, said in the same words SpotSessionPause uses for the
  # cost of a ceiling pause, because it is the same cost.
  HALTED_MESSAGE =
    "This turn was still running #{GRACE.inspect} after the session was preempted, with the fleet " \
    "still at its concurrency limit, so it was stopped where it stands. Whatever was written to disk " \
    "stays written; the tool call in flight is lost. The session is dormant in the spot queue and " \
    "resumes automatically once the fleet has a free slot."

  # What a sweep pass did. `released` is the good outcome and `halted` is the
  # expensive one, so they are counted apart rather than as "resolved".
  Sweep = Data.define(:released, :halted, :waiting) do
    def to_h = { released: released, halted: halted, waiting: waiting }
  end

  class << self
    # Make room for one priority session, if the fleet is full and there is a
    # spot session that can reasonably yield.
    #
    # Called from SpotSessionHold.hold_if_needed's priority branch — the choke
    # point every turn already passes through, and therefore the exact moment
    # "a priority session is about to start with no free slot" is knowable.
    #
    # NEVER RAISES, and never for a stylistic reason: its caller is the gate
    # whose entire promise is that it only defers, and an exception escaping it
    # reaches AgentSessionJob, which marks the session `failed`. A preemption
    # that cannot be worked out is a preemption that does not happen.
    #
    # @param session [Session] the priority session about to take a slot
    # @param logger [StructuredLogger, nil]
    # @return [Session, nil] the session marked to yield, or nil
    def make_room_for(session, logger: nil)
      logger ||= StructuredLogger.new({ service: "SpotPreemption" })
      return nil unless eligible_beneficiary?(session)

      occupancy = SpotGateService.fleet_occupancy
      return nil unless occupancy.at_cap?

      victim = choose_victim
      return nil if victim.nil?

      mark!(victim, session, occupancy, logger) ? victim : nil
    rescue StandardError => e
      logger&.warn("Could not preempt a spot session", session_id: session&.id,
        error: "#{e.class}: #{e.message}")
      Rails.logger.warn("[SpotPreemption] Could not preempt for session #{session&.id}: #{e.class}: #{e.message}")
      nil
    end

    # One pass over the marks that have not yet turned into a dormant session:
    # release the ones the fleet no longer needs, halt the ones that have stood
    # too long, leave the rest inside their grace.
    #
    # Runs from SpotCeilingSweepJob, ahead of SpotSessionPause.sweep!, so a
    # session this pass puts to sleep is in the queue by the time the resume half
    # counts it.
    #
    # Never raises, for the reason every cron sweep in this area does not: the
    # condition is re-read from scratch five minutes later, so a failed pass
    # costs a pass.
    #
    # @return [Sweep]
    def sweep!(logger: nil)
      logger ||= StructuredLogger.new({ service: "SpotPreemption" })
      marked = marked_sessions.to_a
      return Sweep.new(released: 0, halted: 0, waiting: 0) if marked.empty?

      # ONE reading for the whole pass. Asking per session would let the fleet
      # cross the cap halfway down the list and release some marks while halting
      # others on the strength of the same fleet.
      occupancy = SpotGateService.fleet_occupancy

      unless occupancy.at_cap?
        released = marked.count { |victim| release!(victim, logger) }
        logger.info("The fleet fell back under its cap — released preemption marks",
          released: released, marked: marked.size, **occupancy.to_h)
        return Sweep.new(released: released, halted: 0, waiting: marked.size - released)
      end

      overdue, inside_grace = marked.partition { |victim| overdue?(victim) }
      halted = overdue.count { |victim| halt!(victim, logger) }

      logger.info("Preemption marks that outlasted their grace were halted",
        halted: halted, overdue: overdue.size, inside_grace: inside_grace.size, **occupancy.to_h)

      Sweep.new(released: 0, halted: halted, waiting: marked.size - halted)
    rescue StandardError => e
      logger.warn("Spot preemption sweep failed", error: "#{e.class}: #{e.message}")
      Sweep.new(released: 0, halted: 0, waiting: 0)
    end

    # Sessions marked to yield a slot that are still RUNNING — the mark has been
    # written but the turn has not ended, so the session is neither in the queue
    # nor out of the fleet. This is the only population #sweep! acts on; once a
    # marked session goes dormant it belongs to SpotSessionPause's resume.
    def marked_sessions
      Session
        .where(status: :running)
        .where("metadata->>? = ?", SpotSessionPause::PAUSED_REASON, SpotSessionPause::PREEMPTED_REASON)
        .order(:id)
    end

    # Running spot sessions that could yield a slot right now, before ranking.
    #
    # Mirrors SpotSessionPause.pausable_sessions and adds the one exclusion that
    # is specific to this class: a session already carrying a pause record of any
    # kind. Its slot is already on its way back, whoever wrote that record owns
    # its story, and picking it would spend a preemption on nothing.
    def preemptable_sessions
      Session.spot
        .where(status: :running, agent_runtime: ClaudeAuthProvider::RUNTIME)
        .excluding_status_summary_forks
        .where("metadata->>? IS NULL", SpotSessionPause::PAUSED_REASON)
    end

    # How many times this session has yielded a slot to priority work, ever.
    # Survives the resume on purpose — see COUNT.
    def preempt_count(session)
      (session.metadata || {})[COUNT].to_i
    end

    # Whether this session is inside its post-preemption cooldown.
    def cooling_down?(session, now: Time.current)
      last = parse_time((session.metadata || {})[LAST_AT])
      last.present? && last + COOLDOWN > now
    end

    private

    # Whether this session is one a preemption could be FOR. Three refusals, and
    # each of them is a case where taking a slot away would buy nothing:
    #
    #   * A spot session. It answers to the gate; the gate holds it rather than
    #     clearing a path for it.
    #   * A session that is already `running`. It holds a slot of its own, which
    #     is counted in the occupancy read below — preempting for it would take a
    #     second slot for one session. Since #1040 an ordinary turn reaches the
    #     gate `waiting`, so this is the same residual case
    #     SpotSessionHold::RUNNING_HOLD_REASONS covers.
    #   * A Codex session or a status-summary fork. Neither takes a Claude Code
    #     slot as the cap counts it, so neither needs one made.
    def eligible_beneficiary?(session)
      return false if session.nil?
      return false unless enabled?
      return false if session.spot?
      return false if session.running?
      return false unless session.agent_runtime == ClaudeAuthProvider::RUNTIME
      return false if session.status_summary_fork?

      true
    end

    # Preemption rides on the spot gate's own switch, plus one of its own.
    #
    # Both, not either. With gating off there is no spot policy at all and
    # interrupting spot work in its name would be incoherent; the dedicated
    # switch exists so an operator who wants the rest of the policy can turn off
    # the one part of it that stops work already underway, without turning the
    # gate off and letting the whole fleet run unpaced.
    def enabled?
      setting = AppSetting.current
      setting.spot_gating_enabled && setting.spot_preemption_enabled
    end

    # The running spot session that yields, or nil when none should.
    def choose_victim
      candidates = preemptable_sessions.to_a
      return nil if candidates.empty?

      overrides = AppSetting.current.genesis_class_overrides
      candidates = candidates.reject { |s| cooling_down?(s) || !s.spot?(overrides) }
      return nil if candidates.empty?

      involvement = human_message_counts(candidates)
      candidates.min_by do |s|
        [ s.precedence.to_i, preempt_count(s), involvement[s.id].to_i, -s.created_at.to_i, -s.id ]
      end
    end

    # HumanMessage rows per session, for the involvement tiebreak. Counted on the
    # session ITSELF rather than across its hierarchy, the same reading
    # Sessions::HumanInterventionPromotion uses and for the same reason: a human
    # speaking to a router is context about the router, not involvement in the
    # session doing the work.
    def human_message_counts(sessions)
      HumanMessage.where(session_id: sessions.map(&:id)).group(:session_id).count
    rescue ActiveRecord::ActiveRecordError => e
      # An unreadable count degrades to "nobody is involved anywhere", which
      # leaves precedence and the ledger deciding. Refusing to preempt at all
      # would be the wrong direction: the tiebreak is a refinement, not a
      # precondition.
      Rails.logger.warn("[SpotPreemption] Could not read human-message counts: #{e.message}")
      {}
    end

    # Write the pause record onto a still-running session and let its own turn
    # end carry it into the queue.
    #
    # The record is SpotSessionPause's, key for key, because the session it
    # produces has to be indistinguishable from any other sleeper in that queue
    # to the sweep that resumes it. What differs is `spot_pause_reason` and the
    # sentence beside it, which is what every surface reads to explain the stop.
    def mark!(victim, beneficiary, occupancy, logger)
      detail = detail_for(beneficiary, occupancy)
      marked = false

      ActiveRecord::Base.transaction do
        victim.lock!
        # Re-asked under the lock. Choosing a victim reads a list; between that
        # read and this write the session can have ended its turn, been promoted
        # to priority by a human pressing the button on its own page, or been
        # marked by a second priority session starting in the same instant.
        raise ActiveRecord::Rollback unless victim.running? &&
          victim.spot? &&
          !SpotSessionPause.pause_record?(victim)

        metadata = victim.metadata || {}
        victim.merge_metadata!(
          {
            SpotSessionPause::PAUSED_AT => Time.current.utc.iso8601,
            SpotSessionPause::PAUSED_REASON => SpotSessionPause::PREEMPTED_REASON,
            SpotSessionPause::PAUSED_DETAIL => detail,
            SpotSessionPause::PAUSED_COUNT => metadata[SpotSessionPause::PAUSED_COUNT].to_i + 1,
            SpotSessionPause::PREEMPT_MARKED_AT => Time.current.utc.iso8601,
            SpotSessionPause::PREEMPT_FOR_SESSION => beneficiary.id,
            COUNT => metadata[COUNT].to_i + 1,
            LAST_AT => Time.current.utc.iso8601,
            "paused_by" => SpotSessionPause::PAUSED_BY,
            # What actually makes the session dormant when its turn ends. The
            # provenance rides in the same statement so the sleep can name its
            # own cause (#608).
            **Sessions::StopRecord.pending_sleep(Sessions::StopRecord::SPOT_PAUSE)
          },
          # "Sleep only if something is still armed to wake you" is the wrong
          # rule for a sleep somebody else decided on: this session has nothing
          # armed and needs none — the spot queue is what is coming for it. Left
          # in place, a session carrying it from an earlier system-recovery
          # resume would reach its turn end, find nothing armed, drop the sleep,
          # and come to rest in needs_input holding a queue record no sweep acts
          # on. Same reasoning as Sessions::PauseIntoSpotQueue.
          [ SessionStateMachine::PENDING_SLEEP_REQUIRES_WAKE ]
        )
        marked = true
      end
      return false unless marked

      victim.logs.create!(level: "warning", content: mark_message(detail))
      logger.info("Marked a running spot session to yield its slot",
        session_id: victim.id, for_session_id: beneficiary.id,
        precedence: victim.precedence, preempted_before: preempt_count(victim) - 1)
      true
    rescue StandardError => e
      logger.warn("Could not mark a spot session for preemption",
        session_id: victim.id, error: "#{e.class}: #{e.message}")
      false
    end

    # The slot came back without this session having to give anything up.
    #
    # Clearing `pending_sleep` is the whole of it: without the flag the turn ends
    # the way any turn ends, and the session comes to rest wherever it would have
    # anyway. A session that has already gone dormant is skipped under the lock —
    # its record is the queue's now, and stripping it there would drop the
    # session out of the population its resume is keyed on.
    def release!(victim, logger)
      released = false

      ActiveRecord::Base.transaction do
        victim.lock!
        raise ActiveRecord::Rollback unless victim.running? && SpotSessionPause.preempted?(victim)

        victim.remove_metadata!(
          SpotSessionPause::METADATA_KEYS, "paused_by", "pending_sleep",
          SessionStateMachine::PENDING_SLEEP_REQUIRES_WAKE,
          Sessions::StopRecord::PENDING_SLEEP_REASON
        )
        released = true
      end
      return false unless released

      victim.logs.create!(level: "info", content: RELEASED_MESSAGE)
      logger.info("Released a preemption mark — the fleet has room again", session_id: victim.id)
      true
    rescue StandardError => e
      logger.warn("Could not release a preemption mark",
        session_id: victim.id, error: "#{e.class}: #{e.message}")
      false
    end

    # The turn is not ending on its own and the fleet is still over its cap, so
    # it is stopped where it stands.
    #
    # Sessions::HaltRunningTurn rather than a second copy of the terminate-then-
    # pause dance: the pause record and `pending_sleep` are already written, which
    # is exactly the "park first, halt second" order that class documents — a halt
    # that only partly succeeds degrades to the deferral that was already there
    # rather than to a session dozing with nothing armed.
    def halt!(victim, logger)
      result = Sessions::HaltRunningTurn.call(session: victim, reason: :spot_preemption)
      unless result.halted
        logger.info("A preemption mark could not be halted this pass",
          session_id: victim.id, reason: result.reason)
        return false
      end

      victim.logs.create!(level: "warning", content: HALTED_MESSAGE)
      logger.info("Halted a preempted spot session that outlasted its grace", session_id: victim.id)
      true
    rescue StandardError => e
      logger.warn("Could not halt a preempted spot session",
        session_id: victim.id, error: "#{e.class}: #{e.message}")
      false
    end

    def overdue?(victim, now: Time.current)
      marked_at = parse_time((victim.metadata || {})[SpotSessionPause::PREEMPT_MARKED_AT])
      # No stamp means nothing can say how long this has stood, and escalating on
      # that would halt a turn on the strength of an unreadable record. It stays
      # marked; its own turn end still puts it in the queue.
      return false if marked_at.nil?

      marked_at + GRACE < now
    end

    def detail_for(beneficiary, occupancy)
      "Preempted by a priority session. Session ##{beneficiary.id} is priority, and priority work is " \
        "never held by the concurrency limit — but it does count toward it, and the fleet was at " \
        "#{occupancy.on_a_worker} of #{occupancy.cap} session slots. This spot session was the " \
        "lowest-ranked one running (precedence-first, the spot queue's own order), so it yields the " \
        "slot. Nothing is cancelled: it sleeps in the spot queue and the ceiling sweep resumes it, " \
        "highest precedence first, as soon as the fleet is back under its limit."
    end

    def mark_message(detail)
      "#{detail} Its current turn is not interrupted — the session goes dormant when this turn ends, " \
        "which costs no tool call and no unflushed reasoning. If the fleet falls back under its limit " \
        "before then, the mark is dropped and this session simply carries on. A turn still running " \
        "#{GRACE.inspect} from now with the fleet still full is stopped where it stands."
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
