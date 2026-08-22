# frozen_string_literal: true

# Watches the account pool cross the line between "can serve nothing" and "can
# serve something", and fires the `quota_available` trigger event on the way up.
#
# == Why an edge and not a level
#
# Sessions parked on an exhausted pool used to each carry their own one-off
# schedule trigger, guessing at when the pool would recover. Dozens of those rows
# accumulated, they scaled with the number of parked sessions rather than with the
# number of outages, and a timer knows nothing about which parked session matters
# most. The replacement is one event on the recovery itself, which fires one
# fleet-maintenance session that decides — in precedence order — who runs.
#
# That only works if the event is an edge. A level ("the pool is healthy") is true
# on every sweep for as long as the pool stays healthy, and would spawn a fleet
# session every fifteen minutes forever. So the last observed level is persisted
# (AppSetting#quota_pool_available) and the event fires only on false → true.
#
# == What "available" means
#
# One question: can the pool serve a request at all — is there an account that is
# neither quota_exceeded nor waiting on a human to re-authenticate. That is the
# same predicate AuthOutageParkService parks on (`accounts.available`), which is
# what makes this the edge that un-parks those sessions.
#
# It is deliberately NOT the spot gate's question. SpotGateService asks whether
# utilization is under the operator's targets and whether a fleet slot is free, and
# that policy is unchanged by any of this: the fleet-maintenance session the event
# spawns reads the gate for itself before starting anything. Firing on the gate's
# own answer instead would also make the event fire on a fleet slot opening, which
# is not a quota recovery.
#
# == Fail quiet
#
# Every failure path leaves the stored level alone and fires nothing. A monitoring
# gap must not manufacture a recovery that did not happen — the fleet session it
# would spawn is real work — and the next sweep is fifteen minutes away.
class QuotaAvailabilityMonitor
  EVENT_NAME = "quota_available"

  class << self
    # Observe the pool now, record the level, and fire the event if this is the
    # rising edge.
    #
    # @param runtime [String] the runtime whose pool decides. Claude Code is the
    #   only pool with quota windows; a Codex account has no equivalent.
    # @return [Boolean] true when the event was fired
    def check!(runtime: ClaudeAuthProvider::RUNTIME, logger: nil)
      logger ||= StructuredLogger.new({ service: "QuotaAvailabilityMonitor" })

      available = pool_available?(runtime)
      return false if available.nil?

      setting = AppSetting.current
      previous = setting.quota_pool_available

      return false if previous == available

      # The first observation is a baseline, not a transition. Firing on it would
      # spawn a fleet session on the first sweep after every deploy.
      if previous.nil?
        record_level!(setting, available)
        logger.info("Recorded the initial quota availability level", available: available)
        return false
      end

      unless available
        record_level!(setting, false)
        logger.info("Account pool has nothing left to serve — parked sessions wait for the recovery event")
        return false
      end

      # Fire BEFORE recording the level, and only record it once the wake is
      # enqueued. The level is what makes this an edge, so advancing it first
      # would spend the edge on a fire that never happened — and nothing else
      # re-arms it, so every session parked on that outage would wait for the
      # pool to empty and recover all over again.
      logger.info("Account pool has capacity again — firing #{EVENT_NAME}")
      SystemEventTriggerJob.perform_later(EVENT_NAME)
      record_level!(setting, true)
      true
    rescue => e
      logger.warn("Could not evaluate quota availability", error: "#{e.class}: #{e.message}")
      false
    end

    # Record the pool as unable to serve anything, so the next recovery is a real
    # rising edge.
    #
    # Called from a park, which is the moment Zimmer has POSITIVE evidence the
    # pool is empty. Without it the level is only ever sampled every fifteen
    # minutes, and an outage that opens and closes inside one tick is never
    # observed as `false` at all — so the recovery is not an edge, no event
    # fires, and every session parked in that window waits forever. The park is
    # both the earliest and the most certain moment to write it.
    #
    # Best-effort: a park whose bookkeeping fails is still a park.
    def record_unavailable!
      setting = AppSetting.current
      return false if setting.quota_pool_available == false

      record_level!(setting, false)
      true
    rescue => e
      Rails.logger.info "[QuotaAvailabilityMonitor] Could not record the pool as unavailable: #{e.message}"
      false
    end

    # Put the edge back, for a fire that delivered nothing.
    #
    # `SystemEventTriggerJob` calls this when no enabled trigger listened, or when
    # every one of them raised. The pool really is available, but nobody acted on
    # it — and leaving the level at `true` would mean the next sweep sees no
    # transition and the parked sessions stay parked. Re-arming makes the next
    # tick fire again, which is the behaviour a missing or broken fleet trigger
    # should have: keep trying, visibly, rather than silently spending the one
    # chance.
    def rearm!
      setting = AppSetting.current
      return false unless setting.quota_pool_available

      record_level!(setting, false)
      Rails.logger.info "[QuotaAvailabilityMonitor] Re-armed #{EVENT_NAME}: the fire delivered nothing"
      true
    rescue => e
      Rails.logger.info "[QuotaAvailabilityMonitor] Could not re-arm #{EVENT_NAME}: #{e.message}"
      false
    end

    # Fire the wake for a reason that is not the pool's own rising edge.
    #
    # The sweep calls this when a parked SPOT session has become eligible on
    # evidence the edge does not carry — an auth park whose pool credentials
    # changed while `accounts.available` never went false→true. The fleet session
    # re-reads everything for itself, so firing it is safe; not firing it leaves
    # that session with no wake path at all.
    #
    # Deduplicated against the stored level: if the pool is already recorded
    # available, the edge for this recovery has been spent and the fleet session
    # has already run, so this would spawn a second one every fifteen minutes for
    # as long as the session stayed parked. Re-arm instead, and let the next
    # ordinary check! fire it once.
    def request_wake!(reason: nil)
      setting = AppSetting.current

      if setting.quota_pool_available
        Rails.logger.info(
          "[QuotaAvailabilityMonitor] Re-arming #{EVENT_NAME} rather than firing a second time#{" (#{reason})" if reason}"
        )
        record_level!(setting, false)
        return false
      end

      Rails.logger.info "[QuotaAvailabilityMonitor] Firing #{EVENT_NAME}#{" (#{reason})" if reason}"
      SystemEventTriggerJob.perform_later(EVENT_NAME)
      record_level!(setting, true)
      true
    rescue => e
      Rails.logger.info "[QuotaAvailabilityMonitor] Could not request a wake: #{e.message}"
      false
    end

    def record_level!(setting, available)
      setting.update!(quota_pool_available: available, quota_pool_available_changed_at: Time.current)
    end

    # Whether the pool can serve a request right now, or nil when it could not be
    # read. Nil is distinct from false on purpose: an unreadable pool must not be
    # recorded as an outage, or the next successful read would fire a recovery
    # nothing recovered from.
    def pool_available?(runtime)
      RuntimeAuthProvider.for(runtime).accounts.available.exists?
    rescue => e
      Rails.logger.info "[QuotaAvailabilityMonitor] Could not read the #{runtime} pool: #{e.message}"
      nil
    end
  end
end
