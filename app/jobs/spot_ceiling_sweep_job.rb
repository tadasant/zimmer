# frozen_string_literal: true

# Applies the spot policy to sessions that are already RUNNING: pauses them when
# a quota window's spot budget is spent, resumes them when it has room
# down. SpotSessionHold is the same policy at the starting line; this is the
# half that makes the budget a ceiling rather than a floor.
#
# == Cadence
#
# Every 5 minutes in production. The sweep itself is cheap — one
# SpotGateService.evaluate and one indexed query when there is nothing to do —
# so the cadence is not chosen to save work.
#
# What bounds how fast it can react is the READING, not the sweep: utilization
# comes from quota snapshots, which land when ClaudeUsageSamplerJob samples
# (every 15 minutes), when an account rotates, and when someone opens /quotas.
# Sweeping more often than that would re-decide on the same number.
#
# A pass that finds a window out of spot budget is the expensive one: each pause
# terminates a CLI process, and ProcessTerminationService gives each a few
# seconds of SIGTERM grace before escalating. A full fleet is therefore up to
# ~a minute of mostly-waiting work in one run — bounded by "Max sessions at
# once", inside a five-minute cadence, on a queue that is not the agents' one.
#
# == Why a cron rather than something per session
#
# A held session at the starting line re-checks itself, so the load a held
# population puts on the queue grows with the population — the problem
# SpotSessionHold's backoff exists to bound. This sweep costs the same one job
# every five minutes whether nothing is paused or forty sessions are, and one
# reading decides for all of them, which is what a pool-wide condition wants.
class SpotCeilingSweepJob < ApplicationJob
  include SingletonSweep

  def perform
    logger = StructuredLogger.new({ service: "SpotCeilingSweepJob" })
    result = SpotSessionPause.sweep!(logger: logger)

    return if result.paused.zero? && result.resumed.zero?

    logger.info("Spot ceiling sweep acted", **result.to_h)
  end
end
