# frozen_string_literal: true

# Cron entry for FleetIdleMonitor: sample the fleet, and fire
# `no_sessions_in_progress` when it has been idle past the threshold.
#
# == Cadence
#
# Every minute, and that is the resolution of the five-minute threshold rather
# than a busy loop: the idle clock starts at the first observation with nothing
# running, so a coarser cadence would both start the clock late and delay the
# fire by up to a tick. A pass with nothing to do is at most two indexed
# `EXISTS`es over `sessions` and no write at all — FleetIdleMonitor only touches
# `app_settings` on a transition.
#
# Production and staging only. Firing spawns a real session, and a development
# machine that happens to be quiet is not a deployment with idle capacity.
class FleetIdleCheckerJob < ApplicationJob
  include SingletonSweep

  def perform
    FleetIdleMonitor.check!(logger: StructuredLogger.new({ service: "FleetIdleCheckerJob" }))
  end
end
