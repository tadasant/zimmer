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
# neither quota_exceeded nor waiting on a human to re-authenticate.
#
# Deliberately the `status` column (`accounts.available`) rather than the
# evidence-based ClaudeAccount.any_serviceable_for? the PARK decision asks. The
# two are asking different questions: the park decision must not put a session to
# sleep against a label the readings contradict, while this must not announce a
# recovery the pool cannot yet act on — every path that picks an account to spawn
# with reads the column. QuotaResetCheckerJob restores the column and then calls
# this in the same tick, so the level it records is never more than that tick
# stale.
#
# The gate is a SEPARATE question, and it is asked second rather than instead.
# SpotGateService decides whether any spot session may start right now, and the
# session this event spawns exists to start spot work — so a rising edge observed
# while the gate holds announces a recovery nothing can act on. #611 is what that
# costs: 27 fleet sessions in ten hours, every one reading `HELD /
# at_utilization_limit` and waking nobody, each spending a `priority` slot against
# the very window whose utilization was holding the gate.
#
# The two readings drift apart because they measure different things. `accounts`
# go back to `available` when Anthropic's own windows clear (QuotaResetCheckerJob
# restores them on ClaudeAccountQuotaSnapshot#windows_clear?), while the gate
# compares the pool's spend against the OPERATOR's reserve and pacing curve. A
# pool whose accounts are all unflagged but whose weekly spot budget is spent
# reads available and held at the same instant, every fifteen minutes, for days.
#
# So the pool's rising edge is necessary and the gate's assent is sufficient:
#
#   pool NOT available          -> nothing to announce
#   pool available, gate HELD   -> DEFER. The level stays `false`, so the very
#                                  next sweep re-asks. Nothing is spent and
#                                  nothing is lost.
#   pool available, gate allows -> fire.
#
# Deferring rather than spending is what keeps this from becoming the opposite
# bug — an edge that can never fire again, leaving parked sessions asleep
# forever. `check!` runs every fifteen minutes and re-tests both halves; the gate
# opens on a window rolling over, on the fleet's burn falling, or on a slot
# freeing, none of which needs this event to happen first. And it strands no
# PRIORITY work: those parks are resumed directly by
# AuthOutageParkService.wake_parked_sessions!, in the same pass, ungated.
#
# Holding the level at `false` through a deferral is the same move `rearm!`
# already makes for a fire that delivered nothing: the column records whether the
# recovery has been ANNOUNCED, not merely whether the pool is up. That is why
# FleetIdleMonitor no longer reads it — see #pool_available? there, which asks
# the pool directly, because a recovery this monitor has not got round to
# announcing is not an outage.
#
# The hold that defers is the WINDOW's (`at_utilization_limit`), never the fleet
# cap; #spot_gate_hold has the reasoning.
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

      # The pool can serve again — but can anything the wake would start actually
      # run? A deferral leaves the level `false`, so this is re-asked on the next
      # sweep rather than being spent on a session with nothing to hand out.
      if (hold = spot_gate_hold)
        logger.info("Account pool has capacity again, but spot work is held — deferring #{EVENT_NAME}",
          gate_reason: hold.reason, gate_detail: hold.detail)
        return false
      end

      # One transaction, so the level and the job that spends it commit together.
      # Advancing the level first would spend the edge on a fire that never
      # happened; enqueuing first would let a fast worker run the job, find
      # nothing delivered, and read a level that has not been written yet — so
      # its re-arm would no-op and the edge would be lost silently. Inside a
      # transaction the job row is invisible until the level is committed, and a
      # raising enqueue rolls the level back.
      logger.info("Account pool has capacity again — firing #{EVENT_NAME}")
      ActiveRecord::Base.transaction do
        record_level!(setting, true)
        SystemEventTriggerJob.perform_later(EVENT_NAME)
      end
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
    # Scoped to the runtime this monitor actually watches. `quota_pool_available`
    # is one global column and `check!` only ever reads the Claude Code pool, so
    # a Codex park writing `false` here would make the next check see a rising
    # edge against a Claude pool that was healthy throughout — firing a recovery
    # nothing recovered from.
    #
    # Best-effort: a park whose bookkeeping fails is still a park.
    def record_unavailable!(runtime: ClaudeAuthProvider::RUNTIME)
      return false unless runtime.to_s == ClaudeAuthProvider::RUNTIME

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
    # When the edge has already been spent this is a NO-OP, and that is
    # load-bearing. Re-arming here instead reads as harmless — "let the next
    # check! fire it once" — but the sweep runs in the same pass as `check!`, on
    # the same fifteen-minute cron, so the next pass finds the level `false`
    # against an available pool, calls that a rising edge, and fires again. A
    # single spot session the fleet wake legitimately declines to start (the
    # thresholds are still breached, say) then spawns one fleet session every
    # fifteen minutes for as long as it stays parked, each burning the quota that
    # just recovered. That is the exact loop the edge exists to prevent.
    #
    # @return [Boolean] true when a wake was fired
    def request_wake!(reason: nil)
      setting = AppSetting.current

      if setting.quota_pool_available
        Rails.logger.info(
          "[QuotaAvailabilityMonitor] #{EVENT_NAME} already fired for this recovery" \
          "#{" (#{reason})" if reason}"
        )
        return false
      end

      # Same gate as `check!`, for the same reason: this fires the same event, to
      # be answered by the same fleet session, which can start nothing while spot
      # work is held. The sweep that asks runs every fifteen minutes and asks
      # again, so a deferral here costs one sweep and no edge.
      if (hold = spot_gate_hold)
        Rails.logger.info(
          "[QuotaAvailabilityMonitor] Not firing #{EVENT_NAME}#{" (#{reason})" if reason}: " \
          "spot work is held (#{hold.reason})"
        )
        return false
      end

      Rails.logger.info "[QuotaAvailabilityMonitor] Firing #{EVENT_NAME}#{" (#{reason})" if reason}"
      ActiveRecord::Base.transaction do
        record_level!(setting, true)
        SystemEventTriggerJob.perform_later(EVENT_NAME)
      end
      true
    rescue => e
      Rails.logger.info "[QuotaAvailabilityMonitor] Could not request a wake: #{e.message}"
      false
    end

    # The gate decision when a WINDOW is refusing spot work, or nil when the
    # event may fire.
    #
    # Deliberately `at_utilization_limit` alone, and not every held decision. The
    # fleet session forces its headroom to zero on any hold, so `fleet_at_cap`
    # looks like an equally good reason to defer — and it is not, because the two
    # holds run on different clocks. A window's hold moves on the window's clock,
    # which is slower than this fifteen-minute sweep: observing it once is good
    # evidence it will still be there in a minute. Cap contention moves on a
    # session's clock, which is far FASTER than the sweep — a slot frees whenever
    # anything finishes. A fleet that habitually runs at its cap would show
    # `fleet_at_cap` to every sweep while ordinary held spot sessions took the
    # freed slots on their own ten-minute ladder (SpotGateService::RETRY_DELAY),
    # and the outage-parked sessions, whose ONLY wake path is this event, would
    # starve behind them. Firing into a full fleet costs one session; never
    # firing costs the whole parked population.
    #
    # It is also the honest scope: this event is the quota pool recovering, and
    # cap contention is not a quota condition at all.
    #
    # Fails OPEN, in both layers: SpotGateService already allows the session on
    # any condition it cannot evaluate, and a raise on the way to asking is
    # treated the same way here. A monitoring gap must not become an outage of
    # every parked session's only wake path — the fleet session re-reads the gate
    # for itself before it starts anything, so a spurious fire is bounded by one
    # session while a suppressed one is not.
    def spot_gate_hold
      decision = SpotGateService.evaluate
      return nil unless decision.held?
      return nil unless decision.reason == SpotGateService::UTILIZATION_REASON

      decision
    rescue => e
      Rails.logger.info "[QuotaAvailabilityMonitor] Could not read the spot gate: #{e.message}"
      nil
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
