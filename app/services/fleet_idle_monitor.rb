# frozen_string_literal: true

# Watches the fleet fall below the work it has room for, and fires the
# `no_sessions_in_progress` trigger event once it has stayed there for the
# configured stretch.
#
# The sibling of QuotaAvailabilityMonitor: same shape, same AppSetting-backed
# level, same fail-quiet posture, and the same SystemEventTriggerJob on the far
# side. What it exists for is the other half of the same problem. The quota event
# says "the pool can serve again, decide who runs"; this one says "there is
# nearly nobody left to run" — so a job that hands work out has a second way to
# be started besides its daily schedule, on exactly the occasions when the
# deployment has capacity and too little running to spend it on.
#
# == What counts as idle
#
# "Idle" means the fleet has little enough to do — never that it cannot do
# anything. The two are easy to confuse and firing on the second is the expensive
# mistake: it hands more work to a deployment that is already blocked, at the
# moment it has the least room for it. So three questions, and all three must
# answer no:
#
#   1. Is the fleet RUNNING `fleet_idle_max_sessions` or more sessions already?
#      One population and one number: sessions with a turn in flight. Every
#      runtime, every scheduling class, and Zimmer's own status-summary forks all
#      count — "is anyone doing anything" is about the deployment's capacity to
#      take on more, and a running Codex session occupies that as much as a
#      Claude one. `fleet_idle_max_sessions = 1` means simply "nothing running".
#
#      "A turn in flight" is deliberately WIDER than "a worker is executing it",
#      and RunningTurns is where that is decided. `running` is stamped when a
#      turn is handed to a session, and the `agents` queue sits between that and
#      a worker picking it up, so on a busy deployment a real share of the number
#      is turns waiting for a slot. They still count: a queued turn is committed
#      demand that will take the next free worker, and topping up on top of it
#      just deepens the queue. What does NOT count is a row asleep on its own
#      future wake with no worker on it — Zimmer refuses to start those, so they
#      can consume nothing. #running_turns reports the split, which is what
#      /inference shows: "15 sessions" reading as a broken counter when 8 were
#      executing and 7 were queued is [#957](https://github.com/tadasant/zimmer/issues/957).
#
#      This is a different population from the one the spot gate's concurrency
#      limit counts, which is Claude Code sessions only and does not skip frozen
#      categories (Session.running_claude_code_count). Both now read through
#      RunningTurns, so they agree about what a `running` row means; they still
#      differ on runtime and on frozen categories, so a fleet running Codex work
#      will not see the same number under both.
#
#      `waiting` sessions do NOT count, of any class, and the reason is what
#      `waiting` actually holds. It is not a queue — it is Zimmer's only resting
#      state short of a terminal one, so sessions asleep on their OWN
#      self-scheduled wake sit in it alongside anything genuinely queued, and the
#      sleepers dominate. The biggest single population is the `open-pr` skill's
#      terminal step: a session that has FINISHED its work and is sleeping on its
#      open PR, for tens of minutes at a time, occupying nothing. A deployment
#      running 5 sessions with 8 asleep beside them has 5 sessions' worth of
#      work, not 13, and a ceiling that counts 13 reads a fleet with more than
#      half its slots empty as full.
#
#      The spot queue is not an exception to that. A dormant spot session is work
#      waiting for capacity, which is the condition top-up exists to relieve
#      rather than a reason to withhold it — and the session this event spawns is
#      PRIORITY and ungated, so it fills an idle machine rather than deepening
#      the queue. Queue depth is a statement about the budget the gate is pacing
#      to, not about how busy the machine is; the gate owns that, and it holds
#      spot work whether or not this event fires.
#
#      The one thing a dormant population does buy, counted, is damping: it keeps
#      the moment between one session ending and the next starting from reading
#      as an idle fleet. `fleet_idle_threshold_minutes` buys that directly and
#      more honestly — the fleet has to stay under the ceiling CONTINUOUSLY for
#      the whole stretch, and `record_busy!` restarts that clock unconditionally
#      the moment any session enters `running`. A fleet that flaps therefore
#      never accumulates a stretch, at any ceiling, and the dwell is what makes a
#      count of running sessions alone safe to fire on.
#
#   2. Is any session parked on an auth outage, of EITHER class? A park is the
#      clearest statement Zimmer makes that work exists and cannot run. This one
#      is deliberately NOT a threshold and not scoped to spot: an outage parks
#      priority sessions too, they are resumed on their own schedule by
#      QuotaResetCheckerJob rather than by anything this event could start, and
#      one parked session is evidence about the POOL rather than about how busy
#      the fleet is. A count would be answering a different question.
#   3. Can the account pool serve a request at all? The same reading
#      QuotaAvailabilityMonitor persists. A pool with nothing to serve makes a
#      quiet fleet a symptom rather than an opportunity, and the session this
#      would spawn is PRIORITY — ungated, so it would start, find the empty pool
#      and park, having re-armed the latch on its way through `running`. That is
#      one wasted session per idle stretch for as long as the outage lasts.
#
# Question 2 is the one that still reads `waiting`, and it is not a count of
# queued work: a park is a specific mark AuthOutageParkService writes on a
# session, and it is evidence about the POOL. "Nobody is running" and "the pool
# is empty" are different facts, and only the second of them is a reason to keep
# quiet.
#
# == Why a latch and not just a level
#
# "The pool recovered" is naturally a transition, so QuotaAvailabilityMonitor can
# read the level on each sweep and fire on false → true. "The fleet is under the
# ceiling" is not: it is a STATE that stays true for as long as the deployment is
# quiet, so a monitor that fired whenever it observed the state would fire every
# sweep, forever, precisely while nothing is happening. That is the failure mode
# this class is built around, and it takes two columns rather than one:
#
#   fleet_idle_since          when the fleet was first OBSERVED under the
#                             ceiling. The clock the threshold is measured
#                             against. NULL means the fleet was at or over it at
#                             the last observation.
#   fleet_idle_event_fired_at when the event last fired, for as long as the row
#                             lives. Two jobs: within one idle stretch it is the
#                             LATCH (set means this stretch has fired), and
#                             across stretches it is the COOLDOWN clock.
#
# == Why a cooldown as well as a latch
#
# The latch alone is not enough, and the reason is circular in a way that is easy
# to miss: the fire spawns a session, that session enters `running`, and running
# is exactly what re-arms the latch. So on a deployment that is quiet for other
# reasons — an empty backlog, a gate that declines — the steady state would be
# one spawned session every threshold plus however long it takes to finish,
# indefinitely. The event's own answer would keep re-qualifying it.
#
# `fleet_idle_min_fire_interval_minutes` is the floor under that.
# `fleet_idle_event_fired_at` is therefore NOT cleared when the fleet gets work —
# only `fleet_idle_since` is — so it survives as the last-fire timestamp. "Has
# this stretch already fired" is then the comparison `fired_at >= idle_since`
# rather than mere presence.
#
# **A ceiling above 1 makes the cooldown the load-bearing half of that pair.** At
# a ceiling of 1 the fire's own session takes the fleet from zero running to one,
# which ends the stretch outright and leaves the cooldown to matter only on the
# next one. Above 1 the fleet is routinely still under the ceiling while that
# session runs, so the stretch does not end on its own and the cooldown is the
# only thing between the deployment and a fire per threshold. It is therefore the
# real cap on top-up frequency: 60 minutes means at most 24 fires a day whatever
# the ceiling is set to.
#
# == Why the sweep is not the only re-arm
#
# Sampling alone would miss a session that started and finished inside one cron
# tick: the sweep would see idle, idle, idle and never re-arm, and the fleet
# would look dead when it was working. The state machine hook is the positive
# evidence — the same role AuthOutageParkService plays for the quota edge, where
# the park is the moment Zimmer KNOWS the pool is empty rather than the moment it
# next happens to look.
#
# `record_busy!` clears the clock on ANY session entering `running`, without
# consulting the ceiling, and that is deliberate. It is not a claim that the
# fleet is too busy — it is what ends the current stretch so the cooldown gets to
# run the cadence. A ceiling-aware version would leave
# `fleet_idle_since` frozen behind `fleet_idle_event_fired_at` on a fleet that
# never climbs above the ceiling, the latch would hold forever, and the event
# would fire exactly once in the deployment's life.
#
# == Why this does not re-arm on an undelivered fire
#
# SystemEventTriggerJob puts the quota edge back when nothing listened, because
# the sessions that edge exists to wake are still parked and waiting. Nothing is
# waiting on this one: an idle fleet with no trigger listening is a deployment
# that has not asked for idle-time work. Re-arming would turn that into one fire
# per sweep for as long as the quiet lasts, which is the exact loop the latch
# exists to prevent. See SystemEventTriggerJob#rearm.
#
# == Fail quiet
#
# Every failure path leaves the stored level alone and fires nothing, for the
# same reason the quota monitor does: the fire spawns a real session, and a
# monitoring gap must not manufacture one.
class FleetIdleMonitor
  # Stored as a condition on live trigger rows, so it is a wire name rather than
  # a description: it reads "no sessions in progress" and means "few enough
  # sessions in progress". Renaming it needs those rows migrated with it.
  EVENT_NAME = "no_sessions_in_progress"

  class << self
    # How few sessions the fleet may be running and still count as idle enough,
    # how long it must stay that way, and the floor between two fires. All three are
    # operator-tunable on /inference, so they are read rather than frozen.
    #
    # Each takes the already-loaded settings row when the caller has one, so a
    # single `check!` decides on one observation of it.
    def max_sessions(setting = AppSetting.current)
      setting.fleet_idle_max_sessions
    end

    def idle_threshold(setting = AppSetting.current)
      setting.fleet_idle_threshold_minutes.minutes
    end

    def min_fire_interval(setting = AppSetting.current)
      setting.fleet_idle_min_fire_interval_minutes.minutes
    end

    # Observe the fleet now, advance the idle clock, and fire the event if this
    # is the moment the clock crosses the threshold with the latch armed and the
    # cooldown spent.
    #
    # @return [Boolean] true when the event was fired
    def check!(logger: nil)
      logger ||= StructuredLogger.new({ service: "FleetIdleMonitor" })

      # Read once and passed down, so the pool level, the three thresholds and
      # the clock below all come from the same observation of the row.
      setting = AppSetting.current

      # One reading of the fleet for the whole decision, for the same reason the
      # settings row is read once: the ceiling test and the log line that
      # explains it must describe the same moment.
      turns = begin
        running_turns
      rescue => e
        Rails.logger.info "[FleetIdleMonitor] Could not read the fleet: #{e.message}"
        nil
      end
      return false if turns.nil?

      idle = fleet_idle?(setting, turns)
      return false if idle.nil?

      unless idle
        cleared = clear_idle_clock!(setting)
        # Which of the three questions answered no, since they clear three
        # different ways and "not idle" alone leaves an operator guessing.
        logger.info("The fleet is not idle enough — #{EVENT_NAME} is armed again",
          reason: not_idle_reason(setting, turns)) if cleared
        return false
      end

      threshold = idle_threshold(setting)

      idle_since = setting.fleet_idle_since
      if idle_since.nil?
        setting.update!(fleet_idle_since: Time.current)
        logger.info("Fleet is under its work ceiling — started the idle clock",
          threshold_seconds: threshold.to_i, max_sessions: max_sessions(setting))
        return false
      end

      now = Time.current
      idle_for = now - idle_since
      return false if idle_for < threshold

      last_fired = setting.fleet_idle_event_fired_at
      if last_fired.present?
        # Already fired for THIS stretch — the latch. Only the fleet reaching its
        # ceiling moves `fleet_idle_since` past it.
        return false if last_fired >= idle_since
        # A previous stretch fired too recently — the cooldown.
        return false if now - last_fired < min_fire_interval(setting)
      end

      # A guarded write, so a `record_busy!` that lands between the read above
      # and this line cannot be overwritten from a stale record. Losing the race
      # means the fleet got work while we were deciding, which is precisely when
      # the event must not fire.
      claimed = AppSetting
        .where(id: setting.id, fleet_idle_since: idle_since, fleet_idle_event_fired_at: last_fired)
        .update_all(fleet_idle_event_fired_at: now, updated_at: now)

      if claimed.zero?
        logger.info("Fleet stopped being idle while #{EVENT_NAME} was being decided — not firing")
        return false
      end

      logger.info("Fleet has been under its work ceiling past the threshold — firing #{EVENT_NAME}",
        idle_since: idle_since.iso8601, idle_for_seconds: idle_for.to_i,
        max_sessions: max_sessions(setting))
      SystemEventTriggerJob.perform_later(EVENT_NAME)
      true
    rescue => e
      logger.warn("Could not evaluate fleet idleness", error: "#{e.class}: #{e.message}")
      false
    end

    # Re-arm on positive evidence: a session just entered `running`.
    #
    # Called from SessionStateMachine on every commit that lands a session in
    # `running`, which is both the earliest and the most certain moment to know
    # the fleet has work. Without it a session that started and finished between
    # two sweeps is invisible, and the event would stay latched against a fleet
    # that has been working.
    #
    # Deliberately unconditional rather than ceiling-aware — see "Why the sweep
    # is not the only re-arm". Ending the stretch is what hands the cadence to
    # the cooldown.
    #
    # Best-effort: a session that runs is still a session that runs, whatever
    # this bookkeeping does.
    #
    # @return [Boolean] true when the idle clock was actually cleared
    def record_busy!
      clear_idle_clock!(AppSetting.current)
    rescue => e
      Rails.logger.info "[FleetIdleMonitor] Could not record the fleet as busy: #{e.message}"
      false
    end

    # How many sessions the fleet is running right now: the number `check!`
    # compares against the ceiling, exposed so /inference and `get_spot_policy`
    # can show the same reading the monitor decides on.
    #
    # Deliberately scoped the way Zimmer's own recovery jobs scope it:
    # CleanupOrphanedSessionsJob and DeploymentRecoveryJob both skip frozen
    # categories, so a `running` row in one is a row nothing will ever repair.
    # Counting it would pin this monitor to "busy" forever with nothing to say
    # why.
    #
    # See "What counts as idle" for why `waiting` sessions are not in this
    # number, and why a turn merely QUEUED for a worker still is.
    def running_sessions
      running_turns.total
    end

    # The same reading, split into the populations `running` actually holds:
    # turns a worker is executing, turns waiting for one behind the `agents`
    # pool, and sleepers that are dropped from the total. RunningTurns owns the
    # distinction; this is where /inference and `get_spot_policy` get it.
    #
    # @return [RunningTurns::Reading]
    def running_turns
      Session.not_in_frozen_category.running_turns
    end

    private

    # Whether the fleet has room for more work right now, or nil when it could
    # not be read.
    #
    # Nil is distinct from false on purpose: an unreadable fleet must not be
    # recorded as idle, or a monitoring gap would spawn work.
    #
    # See "What counts as idle" above for why each question is scoped the way it
    # is. Ordered cheapest-and-commonest first: on a busy deployment the ceiling
    # test is the only one that runs, and its reading is already taken.
    def fleet_idle?(setting, turns)
      return false if turns.total >= max_sessions(setting)

      return false if parked_work?

      pool_available?(setting)
    rescue => e
      Rails.logger.info "[FleetIdleMonitor] Could not read the fleet: #{e.message}"
      nil
    end

    # Which question `fleet_idle?` answered no to, for the log line above.
    #
    # Takes the same reading the predicate decided on rather than re-reading the
    # fleet: `running_turns` is three queries now, not one COUNT, and the two
    # would otherwise disagree whenever a session started between them. The
    # other two questions are asked again because the predicate short-circuits,
    # so it does not always know their answers.
    def not_idle_reason(setting, turns)
      return "at_work_ceiling" if turns.total >= max_sessions(setting)
      return "work_parked_on_auth_outage" if parked_work?
      return "account_pool_empty" unless pool_available?(setting)

      "unknown"
    end

    # Sessions AuthOutageParkService put to sleep on an empty or unusable pool,
    # of either scheduling class. Work that exists and is blocked, which is the
    # opposite of an idle fleet however quiet it looks.
    def parked_work?
      Session
        .where(status: :waiting)
        .where("metadata->>'auth_outage_reason' IS NOT NULL")
        .exists?
    end

    # Whether the account pool can serve anything, asked of the pool itself.
    #
    # Deliberately NOT `AppSetting#quota_pool_available`. That column looks like a
    # pool reading and is really an ANNOUNCEMENT LATCH: QuotaAvailabilityMonitor
    # holds it at `false` through a recovery it has not fired the event for yet —
    # a fire that delivered nothing and was re-armed, or one deferred because the
    # spot gate is at its utilization limit. The second of those can last days,
    # and reading the latch would suppress this event for all of it, on the
    # strength of a spot-budget condition that says nothing about the pool. The
    # session this spawns is PRIORITY and ungated: it would start and run, not
    # find an empty pool and park, so the reason condition 3 exists does not
    # apply. See QuotaAvailabilityMonitor for what the latch means.
    #
    # An unreadable pool reads as available, matching the `nil` (never observed)
    # default: a monitoring gap must not manufacture an outage.
    def pool_available?(_setting)
      QuotaAvailabilityMonitor.pool_available?(ClaudeAuthProvider::RUNTIME) != false
    end

    # Put the idle clock back to "the fleet has work", writing only when there is
    # something to clear — this runs on every session start.
    #
    # `fleet_idle_event_fired_at` is deliberately left alone: it is the cooldown
    # clock as well as the latch, and clearing it here is what would let the
    # event's own session re-qualify it. See "Why a cooldown as well as a latch".
    def clear_idle_clock!(setting)
      return false if setting.fleet_idle_since.nil?

      setting.update!(fleet_idle_since: nil)
      true
    end
  end
end
