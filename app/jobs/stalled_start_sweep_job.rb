# frozen_string_literal: true

# Finds sessions that were created, queued, and then forgotten — and starts them.
#
# A session's first turn rides on exactly one AgentSessionJob, and a session that
# has never run carries no marker saying so. Lose that job and the row sits in
# `waiting` looking exactly like a session created a moment ago, which is why no
# other sweep has ever looked at it: `CleanupOrphanedSessionsJob` and
# `DeploymentRecoveryJob` scan `running` and the `paused_by = 'recovery'`
# population, and the three dormant-session sweeps each read a marker this
# session does not have. Session 10426 sat in `waiting` for three days.
#
# Every rule about what counts as stalled, and what is done about it, lives in
# StalledSessionStart. Cadence is five minutes, matching the other repair sweeps:
# a pass with nothing to do is one indexed query over the waiting population.
class StalledStartSweepJob < ApplicationJob
  include SingletonSweep

  def perform
    logger = StructuredLogger.new({ service: "StalledStartSweepJob" })
    result = StalledSessionStart.sweep!(logger: logger)

    return if result.stalled.zero?

    logger.info("Stalled-start sweep acted", **result.to_h)
  end
end
