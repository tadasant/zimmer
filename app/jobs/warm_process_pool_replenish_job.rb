# frozen_string_literal: true

# Keeps WarmProcessPool full: recycles a warm router process that has exited,
# aged out or gone stale, sweeps what an earlier worker left on disk, and boots
# a replacement.
#
# Enqueued by AgentSessionJob on every claim, so the next request finds a
# process within one build, and on a one-minute cron as the backstop that
# converges after a deploy or worker restart, which ends every warm process.
#
# On `maintenance`, in the same worker process as the agent jobs: a warm
# process is a child of this process and lives in its memory, which is why only
# this worker's agent jobs can claim it.
class WarmProcessPoolReplenishJob < ApplicationJob
  queue_as :maintenance
  include SingletonSweep

  def perform
    result = WarmProcessPool.replenish!
    return if result[:built].zero? && result[:recycled].zero? && result[:error].nil?

    StructuredLogger.new({ service: "WarmProcessPoolReplenishJob" }).info("Warm process pool replenished", **result)
  end
end
