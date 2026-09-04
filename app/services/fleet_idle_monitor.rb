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
# deployment has capacity and nothing queued to spend it on.
#
# == What counts as idle
#
# "Idle" means the fleet has little enough to do — never that it cannot do
# anything. The two are easy to confuse and firing on the second is the expensive
# mistake: it hands more work to a deployment that is already blocked, at the
# moment it has the least room for it. So three questions, and all three must
# answer no:
#
#   1. Is the fleet holding `fleet_idle_max_sessions` or more sessions already?
#      "Holding" is one number over two populations, because both are work the
#      deployment already has:
#
#        - sessions actually `running`. Every runtime and every scheduling class
#          counts — "is anyone doing anything" is about the deployment's capacity
#          to take on more, and a running Codex session occupies that as much as
#          a Claude one.
#        - spot sessions dormant in `waiting`: paused by the ceiling, held by the
#          gate, or simply never started. Handing a deployment that is already
#          sitting on a spot queue more work would deepen the queue rather than
#          fill an idle machine.
#
#      They are counted together against ONE ceiling rather than vetoing
#      independently, and that is the whole point of the ceiling being a number.
#      As two booleans, a fleet at two of ten slots with a single spot session
#      held at the door was "not idle" — so the event needed the deployment to
#      reach literally zero on both counts before it would top the backlog up,
#      and a ten-slot fleet ran at two. With one ceiling of N, either population
#      can grow into the same headroom and the operator has one number to reason
#      about. `fleet_idle_max_sessions = 1` is exactly the pair of booleans this
#      replaced: nothing running AND nothing queued.
#
#      Status-summary forks are excluded from the spot half for the reason
#      SpotSessionPause excludes them from its own spot population: they are
#      Zimmer's own bookkeeping, and a handful stranded in `waiting` would
#      otherwise eat the whole ceiling.
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
# Priority sessions merely `waiting` deliberately do NOT count. Priority work is
# never gated on quota, so an unparked priority session sitting in `waiting` is
# one in the seconds before its job picks it up, not a queue — counting it would
# suppress the event on ordinary churn.
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
# **A ceiling above 1 makes the cooldown the load-bearing half of that pair.**
# With the old boolean the fire's own session took the fleet from zero running to
# one, which was enough to end the stretch outright; the cooldown only mattered
# on the next stretch. Under a ceiling, the fleet is routinely still under it
# while the spawned session runs, so the stretch never ends on its own and the
# cooldown is the only thing between the deployment and a fire per threshold. It
# is also therefore the real cap on top-up frequency: 60 minutes means at most 24
# fires a day whatever the ceiling is set to.
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
# consulting the ceiling, and that stays true deliberately. It is not a claim
# that the fleet is now too busy — it is what ends the current stretch so the
# cooldown gets to run the cadence. A ceiling-aware version would leave
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
  # a description. It reads "no sessions in progress" and now means "few enough
  # sessions in progress"; renaming it would need those rows migrated with it.
  EVENT_NAME = "no_sessions_in_progress"

  class << self
    # How few sessions the fleet may hold and still count as idle enough, how
    # long it must stay that way, and the floor between two fires. All three are
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

      idle = fleet_idle?(setting)
      return false if idle.nil?

      unless idle
        cleared = clear_idle_clock!(setting)
        logger.info("The fleet is at its work ceiling — #{EVENT_NAME} is armed again") if cleared
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

    # How many sessions the fleet is holding right now: the number `check!`
    # compares against the ceiling, exposed so /inference and `get_spot_policy`
    # can show the same reading the monitor decides on.
    #
    # See "What counts as idle" for why these two populations share one number.
    def sessions_in_hand
      running_count + queued_spot_count
    end

    private

    # Whether the fleet has room for more work right now, or nil when it could
    # not be read.
    #
    # Nil is distinct from false on purpose: an unreadable fleet must not be
    # recorded as idle, or a monitoring gap would spawn work.
    #
    # See "What counts as idle" above for why each question is scoped the way it
    # is. Ordered cheapest-and-commonest first: on a busy deployment the running
    # count is the only query this makes, because it alone can reach the ceiling.
    def fleet_idle?(setting)
      ceiling = max_sessions(setting)

      # Two counts, short-circuited on the first: the running population alone
      # can reach the ceiling, and on a busy deployment it does.
      running = running_count
      return false if running >= ceiling
      return false if running + queued_spot_count >= ceiling

      return false if parked_work?

      pool_available?(setting)
    rescue => e
      Rails.logger.info "[FleetIdleMonitor] Could not read the fleet: #{e.message}"
      nil
    end

    # Anything actually executing. Deliberately scoped the way Zimmer's own
    # recovery jobs scope it: CleanupOrphanedSessionsJob and DeploymentRecoveryJob
    # both skip frozen categories, so a `running` row in one is a row nothing will
    # ever repair. Counting it would pin this monitor to "busy" forever with
    # nothing to say why.
    def running_count
      Session.not_in_frozen_category.where(status: :running).count
    end

    # Spot sessions dormant in the queue: paused by the ceiling, held by the
    # gate, or simply never started. All of them are work the deployment already
    # holds, so they count toward the same ceiling running ones do.
    #
    # Status-summary forks are excluded for the reason SpotSessionPause excludes
    # them from its own spot population: they are Zimmer's own bookkeeping, and
    # ones stranded in `waiting` would otherwise suppress the event indefinitely.
    def queued_spot_count
      Session.spot.where(status: :waiting).excluding_status_summary_forks.count
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
    # default this replaced: a monitoring gap must not manufacture an outage.
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
