# frozen_string_literal: true

# Watches the fleet sit still, and fires the `no_sessions_in_progress` trigger
# event once it has had nothing running and nothing queued for five continuous
# minutes.
#
# The sibling of QuotaAvailabilityMonitor: same shape, same AppSetting-backed
# level, same fail-quiet posture, and the same SystemEventTriggerJob on the far
# side. What it exists for is the other half of the same problem. The quota event
# says "the pool can serve again, decide who runs"; this one says "there is
# nobody left to run" — so a job that hands work out has a second way to be
# started besides its daily schedule, on exactly the occasions when the
# deployment has capacity and nothing queued to spend it on.
#
# == What counts as idle
#
# Two questions, and both must answer no:
#
#   1. Is any session `running`? Every runtime and every scheduling class counts
#      — "is anyone doing anything" is about the deployment's capacity to take on
#      more, and a running Codex session occupies that as much as a Claude one.
#   2. Is any spot session `waiting`? A queued spot session is work the
#      deployment already has and has not started yet, so the fleet is not out of
#      things to do — it is blocked, or waiting its turn at the gate. Handing it
#      more work would deepen a queue rather than fill an idle machine.
#
# Priority sessions in `waiting` deliberately do NOT hold the event off. Priority
# work is never gated on quota, so a priority session sitting in `waiting` is one
# in the seconds before its job picks it up, not a queue — treating it as one
# would suppress the event on ordinary churn.
#
# == Why a latch and not just a level
#
# "The pool recovered" is naturally a transition, so QuotaAvailabilityMonitor can
# read the level on each sweep and fire on false → true. "Nothing is running" is
# not: it is a STATE that stays true for as long as the deployment is quiet, so a
# monitor that fired whenever it observed the state would fire every sweep,
# forever, precisely while nothing is happening. That is the failure mode this
# class is built around, and it takes two columns rather than one:
#
#   fleet_idle_since          when the fleet was first OBSERVED with nothing
#                             running. The clock IDLE_THRESHOLD is measured
#                             against. NULL means something was running at the
#                             last observation.
#   fleet_idle_event_fired_at when the event was fired for the CURRENT idle
#                             stretch. NULL means the latch is armed.
#
# The latch is only cleared by a session actually running — #record_busy!, called
# from the state machine the moment any session enters `running`, and by this
# sweep the next time it observes one. So the event fires ONCE on entering the
# idle-for-five-minutes state, and cannot fire again until the fleet has done
# something in between.
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
  EVENT_NAME = "no_sessions_in_progress"

  # How long the fleet must have had nothing running before the event fires.
  IDLE_THRESHOLD = 5.minutes

  class << self
    # Observe the fleet now, advance the idle clock, and fire the event if this
    # is the moment the clock crosses IDLE_THRESHOLD with the latch armed.
    #
    # @return [Boolean] true when the event was fired
    def check!(logger: nil)
      logger ||= StructuredLogger.new({ service: "FleetIdleMonitor" })

      idle = fleet_idle?
      return false if idle.nil?

      setting = AppSetting.current

      unless idle
        cleared = clear_idle_state!(setting)
        logger.info("The fleet has work — #{EVENT_NAME} is armed again") if cleared
        return false
      end

      if setting.fleet_idle_since.nil?
        setting.update!(fleet_idle_since: Time.current, fleet_idle_event_fired_at: nil)
        logger.info("Fleet has nothing running and nothing queued — started the idle clock",
          threshold_seconds: IDLE_THRESHOLD.to_i)
        return false
      end

      # Already fired for this stretch. Only the fleet having work again — a
      # session running, or one queued in the spot queue — clears it.
      return false if setting.fleet_idle_event_fired_at.present?

      idle_for = Time.current - setting.fleet_idle_since
      return false if idle_for < IDLE_THRESHOLD

      # One transaction, for the reason QuotaAvailabilityMonitor states: writing
      # the latch first would spend it on a fire that never happened, and
      # enqueuing first would let a fast worker read a latch that has not been
      # written yet.
      logger.info("Fleet has been idle past the threshold — firing #{EVENT_NAME}",
        idle_since: setting.fleet_idle_since.iso8601, idle_for_seconds: idle_for.to_i)
      ActiveRecord::Base.transaction do
        setting.update!(fleet_idle_event_fired_at: Time.current)
        SystemEventTriggerJob.perform_later(EVENT_NAME)
      end
      true
    rescue => e
      logger.warn("Could not evaluate fleet idleness", error: "#{e.class}: #{e.message}")
      false
    end

    # Re-arm on positive evidence: a session just entered `running`.
    #
    # Called from SessionStateMachine on every commit that lands a session in
    # `running`, which is both the earliest and the most certain moment to know
    # the fleet is not idle. Without it a session that starts and finishes
    # between two sweeps is invisible, and the event would stay latched against a
    # fleet that has been working.
    #
    # Best-effort: a session that runs is still a session that runs, whatever
    # this bookkeeping does.
    #
    # @return [Boolean] true when idle state was actually cleared
    def record_busy!
      clear_idle_state!(AppSetting.current)
    rescue => e
      Rails.logger.info "[FleetIdleMonitor] Could not record the fleet as busy: #{e.message}"
      false
    end

    private

    # Whether nothing is running and nothing is queued right now, or nil when it
    # could not be read.
    #
    # Nil is distinct from false on purpose: an unreadable fleet must not be
    # recorded as idle, or a monitoring gap would spawn work.
    #
    # See "What counts as idle" above for why each half is scoped the way it is.
    def fleet_idle?
      return false if Session.where(status: :running).exists?

      !queued_spot_work?
    rescue => e
      Rails.logger.info "[FleetIdleMonitor] Could not read the fleet: #{e.message}"
      nil
    end

    # Spot sessions dormant in the queue: paused by the ceiling, held by the
    # gate, parked on quota, or simply never started. All of them are work the
    # deployment already holds, so none of them is an idle fleet.
    #
    # Status-summary forks are excluded for the reason SpotSessionPause excludes
    # them from its own spot population: they are Zimmer's own bookkeeping, and
    # one stranded in `waiting` would otherwise suppress the event indefinitely.
    def queued_spot_work?
      Session.spot.where(status: :waiting).excluding_status_summary_forks.exists?
    end

    # Put both columns back to "nothing observed, latch armed", writing only when
    # there is something to clear — this runs on every session start.
    def clear_idle_state!(setting)
      return false if setting.fleet_idle_since.nil? && setting.fleet_idle_event_fired_at.nil?

      setting.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil)
      true
    end
  end
end
