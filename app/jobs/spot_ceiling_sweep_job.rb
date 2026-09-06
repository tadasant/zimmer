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
# comes from quota snapshots, which land when ClaudeUsageSamplerJob samples (the
# serving account every 15 minutes, a spare within 75), when an account rotates,
# and when someone opens /inference.
# Sweeping more often than that would re-decide on the same number.
#
# A pass that finds a window out of spot budget is the expensive one: each pause
# terminates a CLI process, and ProcessTerminationService gives each a few
# seconds of SIGTERM grace before escalating. A full fleet is therefore up to
# ~a minute of mostly-waiting work in one run — bounded by "Max sessions at
# once", inside a five-minute cadence, on a queue that is not the agents' one.
#
# == It also resolves preemption marks
#
# The concurrency ceiling has the same shape as the budget one since
# SpotPreemption: a priority session that finds the fleet full marks a running
# spot session to yield its slot at the end of its turn. That mark is the one
# state in the spot policy that is neither running-as-usual nor dormant, so it
# needs a pass to resolve it — released when the fleet fell back under its cap on
# its own, halted when the turn outlasted SpotPreemption::GRACE with the fleet
# still full. This job is that pass, and it takes it before the pause/resume half
# so both halves decide on the same fleet.
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

    # Preemption marks FIRST, and the order is load-bearing. A mark is a session
    # on its way out of the fleet that has not left yet; resolving it here means
    # a session this pass sends to sleep is already in the queue by the time the
    # resume half below counts free slots, and a mark this pass RELEASES stops
    # looking like a slot that is about to free. Running the two the other way
    # round would have each pass decide on the previous pass's fleet.
    preemption = SpotPreemption.sweep!(logger: logger)
    result = SpotSessionPause.sweep!(logger: logger)

    logger.info("Spot preemption marks resolved", **preemption.to_h) if
      preemption.released.positive? || preemption.halted.positive?

    return if result.paused.zero? && result.resumed.zero?

    logger.info("Spot ceiling sweep acted", **result.to_h)
  end
end
