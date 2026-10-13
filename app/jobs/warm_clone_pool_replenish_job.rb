# frozen_string_literal: true

# Keeps WarmClonePool full: builds a ready clone of each repository
# WarmPoolPolicy names when the pool is short of it, and recycles clones that
# have aged out.
#
# Enqueued by AgentSessionJob on every claim, so the next session on that key
# finds a clone within one build (~10s), and on a one-minute cron as the
# backstop that converges after a deploy, a failed build, or a claim whose
# enqueue was absorbed by the singleton guard while a pass was already running.
# A pass over a full, fresh pool lists one directory and does nothing else.
#
# On `maintenance`: a build is a `git clone` of a few seconds to a minute, which
# is the kind of work that lane exists to keep off `default`.
class WarmClonePoolReplenishJob < ApplicationJob
  queue_as :maintenance
  include SingletonSweep

  def perform
    result = WarmClonePool.replenish!
    return if result[:built].zero? && result[:recycled].zero? && result[:failed].nil?

    StructuredLogger.new({ service: "WarmClonePoolReplenishJob" }).info("Warm clone pool replenished", **result)
  end
end
