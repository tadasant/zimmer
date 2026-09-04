# frozen_string_literal: true

# Cron entry for FleetIdleMonitor: sample the fleet, and fire
# `no_sessions_in_progress` when it has held fewer sessions than its ceiling for
# longer than the threshold.
#
# == Cadence
#
# Every minute, and that is the resolution of the threshold rather than a busy
# loop: the idle clock starts at the first observation under the ceiling, so a
# coarser cadence would both start the clock late and delay the fire by up to a
# tick. A minute is also the floor the threshold is validated against, since a
# stretch shorter than the sampling interval could not be observed. A busy pass
# is one indexed `COUNT` over `sessions` and nothing else; a quiet one adds two
# more plus the settings row, and writes only on a transition.
#
# Production and staging only. Firing spawns a real session, and a development
# machine that happens to be quiet is not a deployment with idle capacity.
class FleetIdleCheckerJob < ApplicationJob
  include SingletonSweep

  def perform
    FleetIdleMonitor.check!(logger: StructuredLogger.new({ service: "FleetIdleCheckerJob" }))
  end
end
