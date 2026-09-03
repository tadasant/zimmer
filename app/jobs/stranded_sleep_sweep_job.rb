# frozen_string_literal: true

# Finds sessions asleep in `waiting` on a wake-up that can never fire — and wakes
# them.
#
# The sibling of StalledStartSweepJob at the other end of the same hole. That one
# covers a session whose FIRST turn was lost; this one covers a session that ran,
# went to sleep on a wake, and lost the wake. Neither population carries a marker,
# which is why neither was ever swept: `CleanupOrphanedSessionsJob` and
# `DeploymentRecoveryJob` scan `running` and `paused_by = 'recovery'`, and the
# dormant-session sweeps each read a marker these sessions do not have.
#
# Every rule about what counts as stranded, and what is done about it, lives in
# StrandedSleepRescue — including the logging, so this job adds no line of its
# own. Cadence is five minutes, matching the other repair sweeps; a pass with
# nothing to do is one indexed query over the waiting population plus one trigger
# lookup per candidate.
class StrandedSleepSweepJob < ApplicationJob
  include SingletonSweep

  def perform
    StrandedSleepRescue.sweep!(logger: StructuredLogger.new({ service: "StrandedSleepSweepJob" }))
  end
end
