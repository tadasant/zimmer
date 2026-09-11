# frozen_string_literal: true

# Re-checks the work backlog's non-`queued` rows and records which of them have
# outlived the reason they left the queue.
#
# A relative of StalledStartSweepJob and StrandedSleepSweepJob, one level up:
# those recover a SESSION that stopped moving, and this one reports on the QUEUE
# ROW behind work that stopped moving. It differs from both in what it is allowed
# to do about it — nothing. It classifies and records; a human or an agent
# triages. WorkBacklog::LivenessSweep says why that line is where it is.
#
# HOURLY. The population is measured in days, the pass costs a few GitHub
# requests per repo, and nothing downstream is waiting on it.
#
# Production and staging only. It spends GitHub API budget on the deployment's
# own repos, and a developer's database is full of `started` rows left over from
# testing whose issues it would go and look up.
class WorkBacklogLivenessSweepJob < ApplicationJob
  include SingletonSweep

  queue_as :pollers

  def perform
    WorkBacklog::LivenessSweep.sweep!(
      logger: StructuredLogger.new({ service: "WorkBacklogLivenessSweepJob" })
    )
  end
end
