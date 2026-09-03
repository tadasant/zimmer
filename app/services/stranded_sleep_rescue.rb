# frozen_string_literal: true

require "automated_prompts"

# Wakes a session that went to sleep on a wake-up that can no longer happen.
#
# == The hole this closes
#
# `waiting` is Zimmer's word for two states that look identical from outside: a
# session resting on a wake it will get, and a session resting on a wake it will
# not. Nothing distinguished them, and nothing looked.
#
# The sweeps that exist all read a MARKER. `CleanupOrphanedSessionsJob` takes the
# `waiting` rows carrying `paused_by = 'recovery'` — and says in its own comment
# that it deliberately leaves everything else alone, "so this never disturbs a
# legitimately-dormant wake_me_up_later session". `SpotHoldSweepJob` reads
# `spot_hold_reason`, `SpotCeilingSweepJob` reads `spot_pause_reason`,
# `QuotaResetCheckerJob` reads the parked population, `AuthOutageParkService`
# reads `auth_outage_reason`. `StalledSessionStart` covers the one `waiting`
# population with no marker at all — but only the half that has NEVER RUN
# (`session_id IS NULL`), because re-running a start job under a session that has
# a conversation would re-clone underneath it.
#
# A session that HAS run, went to sleep on a wake, and lost that wake falls
# through every one of them. It carries no marker (a legitimate sleep does not
# get one), it has a `session_id` (so the stalled-start sweep skips it), and it
# is not `running` (so orphan cleanup never looks at it).
#
# Session 6412 sat there for 38.7 hours — a router mid-way through orchestrating
# several children, holding a multi-session feature arc. Nothing in the fleet
# noticed; a human did, and resumed it by hand, and it picked up immediately.
# https://github.com/tadasant/zimmer/issues/855
#
# == "No fireable wake" is not "no wake"
#
# The predicate that matters is Session#awaiting_scheduled_wake?, and it has to
# ask whether a wake CAN fire rather than whether a wake row exists. In #855 the
# row existed: trigger 13670 read `enabled`, its surviving condition had never
# fired, and it watched a session that had already archived and would never
# transition again. A sweep keyed on the ABSENCE of trigger rows would have
# walked straight past it. SessionStateMachine.one_time_wake_pending? is where
# that question is answered, for this sweep and for every other reader.
#
# == Failing safe
#
# The failure this closes is silent in both directions, so the bias is explicit:
# an unnecessary extra wake costs one agent turn, and a missed one costs however
# long it takes a human to notice. Every judgement here therefore leans toward
# waking:
#
#   * an unreadable trigger table reads as "asleep on purpose" (that is
#     #awaiting_scheduled_wake?'s own rescue) and costs a pass, not a wake;
#   * a watched session whose row cannot be read reads as fireable;
#   * GRACE is generous enough that no in-flight fire is mistaken for a lost one;
#   * anything queued — a pending message, a pending AgentSessionJob — means
#     something is already coming and this sweep stands down;
#   * a session slept deliberately through POST /api/v1/sessions/:id/sleep — the
#     one route into `waiting` that arms nothing — carries
#     Session::DELIBERATE_SLEEP_KEY and is excluded.
#
# == What it does about it
#
# The same door `CleanupOrphanedSessionsJob` uses for a recovery-paused session:
# `Session#claim_system_recovery_turn!` (a `FOR UPDATE` claim that cannot straddle
# an archive) plus a SYSTEM_RECOVERY nudge naming this sweep. That path
# deliberately PRESERVES any wake still armed, so a session woken here that still
# holds an unfireable `ao_event` watcher comes to rest in `needs_input` rather
# than sleeping on it again — visible on the homepage, which is the honest place
# for it.
#
# After MAX_RESCUES it stops and alerts instead: whatever keeps putting the
# session back to sleep with nothing armed is not something more turns will fix,
# and a human should see it.
class StrandedSleepRescue
  # How long a `waiting` session with no fireable wake is given the benefit of the
  # doubt.
  #
  # This is not a race window — by the time a session is in this population the
  # wake is already gone — it is a margin for the paths that legitimately hold a
  # session in `waiting` for a few minutes with nothing armed yet: a trigger
  # being created a moment after `sleep!`, an `AoEventTriggerJob` in flight on a
  # congested `triggers` queue, a wake fired whose resumed turn has not yet been
  # picked up off the `agents` queue. Fifteen minutes covers all three several
  # times over and still bounds the stall at under half an hour.
  GRACE = 15.minutes

  # How many times one session may be rescued before Zimmer stops and leaves it
  # for a human. Each rescue is at least GRACE apart.
  MAX_RESCUES = 3

  # Bounds on one pass. Every action here spends an agent turn, so the action
  # bound is deliberately smaller than StalledSessionStart's: a surprise
  # population must not become a surprise bill.
  #
  # The examined bound is separate and much larger, and the gap between them is
  # load-bearing. The last question — can any of this session's wakes still fire
  # — is answered in Ruby against the trigger rows, so it cannot be a WHERE
  # clause and the candidate set is dominated by sessions sleeping perfectly
  # normally. A single `ORDER BY updated_at LIMIT n` would hand the whole page to
  # them: a legitimate sleeper does not advance `updated_at` while it sleeps, so
  # a `wake_me_up_later` set three days out sits at the head of an oldest-first
  # ordering for three days. Once n of those exist the sweep is permanently blind
  # — and blind while logging `stranded: 0`, which is the worst possible way to
  # fail. So #sweep! PAGES, keeping the cursor moving until it has found enough
  # to act on or examined this many rows.
  MAX_ACTIONS_PER_SWEEP = 5
  PAGE_SIZE = 100
  MAX_EXAMINED_PER_SWEEP = 1_000

  # How many times this sweep has rescued this session. Listed in
  # Session::STALE_RETRY_METADATA_KEYS so an ordinary resume or restart clears it
  # — the budget is about repeated rescues of the same stall, not a lifetime cap.
  RESCUE_COUNT = "stranded_sleep_rescues"

  # Records that this sweep gave up on a session, and when. Also in
  # STALE_RETRY_METADATA_KEYS, so a resume or restart puts the session back in
  # scope.
  ABANDONED = "stranded_sleep_abandoned"

  # Markers that mean "asleep on purpose, and somebody else's sweep owns the way
  # back". Identical to StalledSessionStart::DORMANT_MARKERS, and for the same
  # reason: waking a session out from under the decision that stopped it undoes
  # that decision.
  DORMANT_MARKERS = %w[
    spot_hold_reason
    spot_pause_reason
    auth_outage_reason
    paused_by
  ].freeze

  # The outcome of one pass.
  #
  # `found` is what the pass identified as stranded, NOT how many stranded
  # sessions exist — #find_stranded stops paging the moment it has
  # MAX_ACTIONS_PER_SWEEP of them, so the two are the same number only when the
  # scan ran out of candidates first. `examined` is what makes that legible:
  # `found: 5, examined: 100` is a pass that stopped early, `found: 0,
  # examined: 1000` is a pass that spent its whole budget and saw nothing. A
  # single field claiming to be the size of the problem would be lying in both
  # directions.
  Sweep = Data.define(:rescued, :abandoned, :refused, :found, :examined)

  class << self
    # `waiting` sessions that have run, are not dormant by anyone's marker, have
    # nothing queued and nothing in flight, and have been quiet for `grace`.
    #
    # Everything answerable in SQL is answered here. The one question left for
    # #sweep! is whether a wake can still fire, which is answered in Ruby against
    # the trigger rows — in batches, through Session.ids_awaiting_scheduled_wake,
    # so a page of a hundred costs a fixed handful of queries rather than a
    # hundred.
    #
    # Ordered oldest-first by `updated_at` and paged by (`updated_at`, `id`) so
    # the cursor is total: `updated_at` alone is not unique, and a page boundary
    # landing inside a run of equal timestamps would either skip rows or loop.
    #
    # @return [ActiveRecord::Relation<Session>]
    def candidates(now: Time.current, grace: GRACE)
      cutoff = now - grace

      relation = Session
        .not_in_frozen_category
        .where(status: :waiting)
        # Has run. A session with no runtime id has never taken a turn, and
        # restarting one is StalledSessionStart's job, not this one — resuming it
        # here would deliver a follow-up prompt into a conversation that does not
        # exist.
        .where.not(session_id: [ nil, "" ])
        # Quiet by `updated_at`, which is also the cooldown. A rescue leaves the
        # population by status anyway — the session goes to `running` — but every
        # write this sweep makes to a session (the rescue's metadata clear, the
        # abandon marker) stamps `updated_at` too, so a session that comes back to
        # `waiting` is out of scope for another GRACE regardless.
        .where(updated_at: ...cutoff)
        # Something is already on its way to this session.
        .where("NOT EXISTS (SELECT 1 FROM enqueued_messages WHERE enqueued_messages.session_id = " \
               "sessions.id AND enqueued_messages.status = 'pending')")

      relation = excluded_markers.reduce(relation) do |scope, marker|
        scope.where("sessions.metadata->>? IS NULL", marker)
      end

      PendingAgentTurns.without_a_pending_turn(relation).order(:updated_at, :id)
    end

    # The exclusion markers, in one place: the ones other sweeps own, plus this
    # sweep's own "gave up" marker and the deliberate-sleep marker the REST sleep
    # endpoint stamps.
    def excluded_markers
      DORMANT_MARKERS + [ ABANDONED, Session::DELIBERATE_SLEEP_KEY ]
    end

    # One pass.
    #
    # Never raises: it runs on a cron beside everything else and the condition is
    # re-read from scratch minutes later, so a failed pass costs a pass.
    #
    # @return [Sweep]
    def sweep!(logger: StructuredLogger.new({ service: "StrandedSleepRescue" }))
      batch, examined = find_stranded

      if batch.empty?
        log_exhausted_scan(logger, examined) if examined >= MAX_EXAMINED_PER_SWEEP
        return Sweep.new(rescued: 0, abandoned: 0, refused: 0, found: 0, examined: examined)
      end

      rescued = 0
      abandoned = 0
      refused = 0
      # Alerts are batched for the same reason every sibling trigger job batches
      # them: the incident that produces stranded sleepers produces them in
      # numbers, and one Slack message about five of them is what a human can act
      # on where five messages is noise.
      AlertBatcher.with_batch do
        batch.each do |session|
          case repair!(session, logger)
          when :rescued then rescued += 1
          when :abandoned then abandoned += 1
          else refused += 1
          end
        end
      end

      logger.warn("Resumed sessions that were asleep on a wake that can never fire",
        found: batch.size, examined: examined,
        rescued: rescued, abandoned: abandoned, refused: refused)

      Sweep.new(rescued: rescued, abandoned: abandoned, refused: refused, found: batch.size, examined: examined)
    rescue StandardError => e
      logger.warn("Stranded-sleep sweep failed", error: "#{e.class}: #{e.message}")
      Sweep.new(rescued: 0, abandoned: 0, refused: 0, found: 0, examined: 0)
    end

    private

    # Walk the candidate set oldest-first until MAX_ACTIONS_PER_SWEEP stranded
    # sessions are found or MAX_EXAMINED_PER_SWEEP rows have been looked at.
    #
    # The paging is the whole point — see MAX_EXAMINED_PER_SWEEP. Each page costs
    # one SELECT for the rows plus the fixed handful
    # Session.ids_awaiting_scheduled_wake takes, however many sessions are on it.
    #
    # @return [Array(Array<Session>, Integer)] the sessions to act on, and how
    #   many rows were examined getting to them
    def find_stranded
      found = []
      examined = 0
      cursor = nil

      while found.size < MAX_ACTIONS_PER_SWEEP && examined < MAX_EXAMINED_PER_SWEEP
        page = page_after(cursor)
        break if page.empty?

        examined += page.size
        cursor = [ page.last.updated_at, page.last.id ]

        ids = page.map(&:id)
        sleeping = Session.ids_awaiting_scheduled_wake(ids)
        driven = driven_by_recurring_trigger_ids(ids)
        page.each do |session|
          next if sleeping.include?(session.id) || driven.include?(session.id)

          found << session
          break if found.size >= MAX_ACTIONS_PER_SWEEP
        end
      end

      [ found, examined ]
    end

    # Of +session_ids+, those a RECURRING trigger is going to follow up into.
    #
    # Session#awaiting_scheduled_wake? deliberately ignores recurring conditions —
    # they are not per-session wake-ups — but a recurring trigger holding this
    # session as its reuse target really will deliver into it on its own schedule.
    # A heartbeat set with `set_heartbeat`, or any recurring trigger a user
    # pointed at a session, is a session being DRIVEN rather than a session
    # stranded, and resuming it here would barge a drumbeat that is already on its
    # way.
    #
    # Asked in Ruby rather than SQL because "recurring" is a property of the
    # condition's JSON configuration (a schedule with no `scheduled_at`, a Slack
    # or GitHub feed, a broadcast `ao_event`) rather than of a column — but asked
    # once per PAGE rather than once per session, so it stays a fixed query cost.
    #
    # Fails safe in the same direction as everything else here: an unreadable
    # trigger table means "leave them alone", which costs a pass.
    #
    # @return [Set<Integer>]
    def driven_by_recurring_trigger_ids(session_ids)
      return Set.new if session_ids.empty?

      TriggerCondition
        .joins(:trigger)
        .includes(:trigger)
        .where(triggers: { last_session_id: session_ids, reuse_session: true, status: "enabled" })
        .reject { |condition| condition.one_time_schedule? || condition.session_scoped_ao_event? }
        .map { |condition| condition.trigger.last_session_id }
        .to_set
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error(
        "[StrandedSleepRescue] Could not read recurring triggers for #{session_ids.size} session(s): #{e.message}"
      )
      session_ids.to_set
    end

    # One page of candidates strictly after +cursor+, a `[updated_at, id]` pair.
    def page_after(cursor)
      scope = candidates.limit(PAGE_SIZE)
      return scope.to_a if cursor.nil?

      updated_at, id = cursor
      scope.where(
        "sessions.updated_at > :updated_at OR (sessions.updated_at = :updated_at AND sessions.id > :id)",
        updated_at: updated_at, id: id
      ).to_a
    end

    # Say so when a pass ran out of budget without finding anything.
    #
    # Silence here would be indistinguishable from "the fleet is healthy", and a
    # scan that keeps hitting its ceiling means the sleeping population has grown
    # past what one pass can see — the blindness this sweep's paging exists to
    # prevent, arriving by a slower route.
    def log_exhausted_scan(logger, examined)
      logger.warn(
        "Stranded-sleep sweep examined its whole budget without finding a stranded session",
        examined: examined, budget: MAX_EXAMINED_PER_SWEEP
      )
    end

    # Wake one stranded session, or stop trying.
    #
    # @return [Symbol] :rescued, :abandoned, or :refused
    def repair!(session, logger)
      session.reload
      count = (session.metadata || {})[RESCUE_COUNT].to_i

      # Re-ask under the reload, and BEFORE consulting the budget — the order is
      # load-bearing. A session that armed a wake between the page read and here
      # is not stranded at all, and giving up on it first would stamp it
      # `stranded_sleep_abandoned`, write an error to its timeline and alert,
      # about a session that had just fixed itself.
      if session.awaiting_scheduled_wake? ||
          driven_by_recurring_trigger_ids([ session.id ]).include?(session.id)
        logger.info("Left a session alone — it is not stranded after all", session_id: session.id)
        return :refused
      end

      return give_up!(session, logger, count) if count >= MAX_RESCUES

      outcome = nil
      ActiveRecord::Base.transaction do
        outcome = session.claim_system_recovery_turn! do
          # The budget is spent in the SAME write that clears the stale keys, and
          # inside the same transaction as the enqueue. Incrementing afterwards
          # left a window where a crash — or a raise from the bookkeeping itself —
          # enqueued a turn without spending anything, which makes MAX_RESCUES a
          # suggestion rather than a bound. RESCUE_COUNT is itself in
          # STALE_RETRY_METADATA_KEYS, so it has to be re-added after the except.
          session.update!(
            running_job_id: nil,
            metadata: (session.metadata || {})
              .except(*Session::STALE_RETRY_METADATA_KEYS)
              .merge(RESCUE_COUNT => count + 1)
          )
        end

        next unless outcome == :claimed

        AgentSessionJob.enqueue_with_prompt(
          session.id,
          AutomatedPrompts.system_recovery(
            reason: "Zimmer found this session asleep with no wake-up that could ever fire, and " \
                    "resumed it. If you are still waiting on something, register a fresh " \
                    "wake_me_up_when_session_changes_state watcher AND a wake_me_up_later deadline " \
                    "before ending this turn"
          )
        )

        session.logs.create!(
          level: "warning",
          content: "This session was asleep in `waiting` with no wake-up that could still fire — " \
                   "its wake trigger had been consumed, deleted, or left watching a session that " \
                   "will never transition again. Zimmer's stranded-sleep sweep resumed it " \
                   "(rescue #{count + 1} of #{MAX_RESCUES})."
        )
      end

      unless outcome == :claimed
        logger.info("Could not claim a turn on a stranded session",
          session_id: session.id, outcome: outcome)
        return :refused
      end

      logger.warn("Resumed a session asleep on a wake that could never fire",
        session_id: session.id, rescue_attempt: count + 1)

      AlertService.raise_alert(
        "A sleeping session had no wake-up left",
        details: "Session #{session.id} was in `waiting` with no trigger that could ever fire, and " \
                 "Zimmer resumed it (rescue #{count + 1} of #{MAX_RESCUES}). Something consumed or " \
                 "deleted its wake set without resuming it — see " \
                 "https://github.com/tadasant/zimmer/issues/855.",
        source: "StrandedSleepRescue",
        dedup_key: "stranded_sleep_#{session.id}"
      )

      :rescued
    rescue StandardError => e
      logger.warn("Could not rescue a stranded session",
        session_id: session.id, error: "#{e.class}: #{e.message}")
      :refused
    end

    # Stop rescuing, and stop re-reading the same session forever.
    #
    # `waiting` has no transition to `needs_input` (see
    # SessionStateMachine's event list), and inventing one to park a session in
    # the human's action queue would be a change to the state machine made for a
    # branch that should almost never run. So this does what SessionContinuation
    # does when it gives up: it writes a marker that takes the session out of the
    # population, records why on the session's own timeline, and alerts. A
    # session that has been resumed MAX_RESCUES times and gone straight back to
    # sleep with nothing armed is not a stall Zimmer can fix by trying again.
    #
    # ABANDONED is in Session::STALE_RETRY_METADATA_KEYS, so any ordinary resume
    # or restart — including a human pressing the button this alert asks for —
    # clears it and puts the session back under the sweep's care.
    def give_up!(session, logger, count)
      session.merge_metadata!(ABANDONED => Time.current.iso8601)

      session.logs.create!(
        level: "error",
        content: "Zimmer has resumed this session #{count} times and each time it went back to " \
                 "sleep with no wake-up that could fire. Zimmer has stopped resuming it; a human " \
                 "needs to look at why its wake-ups are not sticking."
      )
      logger.warn("Gave up on a repeatedly-stranded session", session_id: session.id, rescues: count)

      AlertService.raise_alert(
        "A session keeps falling asleep with no wake-up",
        details: "Session #{session.id} has been resumed #{count} times by Zimmer's stranded-sleep " \
                 "sweep and has gone straight back to `waiting` with nothing armed every time. " \
                 "Zimmer has stopped resuming it. Restart it by hand once the reason its wake-ups " \
                 "are not sticking is understood.",
        source: "StrandedSleepRescue",
        dedup_key: "stranded_sleep_abandoned_#{session.id}"
      )

      :abandoned
    rescue StandardError => e
      logger.warn("Could not abandon a repeatedly-stranded session",
        session_id: session.id, error: "#{e.class}: #{e.message}")
      :refused
    end
  end
end
