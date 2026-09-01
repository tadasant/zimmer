# frozen_string_literal: true

# Cron entry for FleetIdleMonitor: sample the fleet, and fire
# `no_sessions_in_progress` when it has had nothing to do past the threshold.
#
# == Cadence
#
# Every minute, and that is the resolution of the five-minute threshold rather
# than a busy loop: the idle clock starts at the first observation with nothing
# running, so a coarser cadence would both start the clock late and delay the
# fire by up to a tick. A busy pass is one indexed `EXISTS` over `sessions` and
# nothing else; a quiet one adds two more plus the settings row, and writes only
# on a transition.
#
# Production and staging only. Firing spawns a real session, and a development
# machine that happens to be quiet is not a deployment with idle capacity.
class FleetIdleCheckerJob < ApplicationJob
  include SingletonSweep

  def perform
    FleetIdleMonitor.check!(logger: StructuredLogger.new({ service: "FleetIdleCheckerJob" }))
  end
end
