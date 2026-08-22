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

      setting.update!(quota_pool_available: available, quota_pool_available_changed_at: Time.current)

      # The first observation is a baseline, not a transition. Firing on it would
      # spawn a fleet session on the first sweep after every deploy.
      if previous.nil?
        logger.info("Recorded the initial quota availability level", available: available)
        return false
      end

      unless available
        logger.info("Account pool has nothing left to serve — parked sessions wait for the recovery event")
        return false
      end

      logger.info("Account pool has capacity again — firing #{EVENT_NAME}")
      SystemEventTriggerJob.perform_later(EVENT_NAME)
      true
    rescue => e
      logger.warn("Could not evaluate quota availability", error: "#{e.class}: #{e.message}")
      false
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
