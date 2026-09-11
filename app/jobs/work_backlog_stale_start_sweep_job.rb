# frozen_string_literal: true

# Re-checks the work backlog's `started` rows and puts back the ones whose
# session ended with nothing to show.
#
# The sibling of StalledStartSweepJob and StrandedSleepSweepJob one level up: both
# of those recover a SESSION that stopped moving, and this one recovers the
# QUEUE ROW behind a session that stopped moving and was never coming back. The
# failure it closes is the same shape — a row in a state nothing ever re-reads —
# and so is the fix: look, decide, and say what was found.
#
# Every rule about which rows are candidates and what is done about each one
# lives in WorkBacklog::StaleStartSweep, including the logging, so this job adds
# no line of its own.
#
# HOURLY, not five-minutely like its two siblings. Nothing here is urgent: the
# population it works on is measured in days, the sweep costs a GitHub read per
# repo, and the item it recovers waits for the groomer's next pull either way.
#
# Production and staging only. It spends GitHub search budget on repos that are
# the deployment's own, and a developer's database is full of `started` rows left
# over from testing whose issues it would go and look up one by one.
class WorkBacklogStaleStartSweepJob < ApplicationJob
  include SingletonSweep

  queue_as :pollers

  def perform
    WorkBacklog::StaleStartSweep.sweep!(
      logger: StructuredLogger.new({ service: "WorkBacklogStaleStartSweepJob" })
    )
  end
end
