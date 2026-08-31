# frozen_string_literal: true

# Repairs the spot gate's re-check ladder: puts a held spot session back on it
# when the re-check it promised never fired.
#
# == Why the ladder needs a backstop at all
#
# SpotSessionHold defers a refused turn by enqueuing ONE delayed job, and each
# re-check forges the next link. There is no redundancy anywhere along that
# chain, so a single lost link strands the session in `waiting` forever — in a
# state indistinguishable, at a glance, from a session merely queued. Nothing
# else was looking: SpotCeilingSweepJob only resumes the `spot_pause_*`
# population, the quota-recovery wake only reads auth-outage parks, and a
# start-held session has no runtime session to restart.
#
# Session 7507 lost its link to a worker shutdown that landed between the hold
# record committing and its re-check being enqueued, and sat there for eleven
# hours showing a human a fossilised "5 of 5 session slots taken" while the live
# gate said 1 of 5 (tadasant/zimmer#648). This job is what makes the durable
# record — `spot_hold_retry_at` on the session — the thing the ladder rests on,
# rather than one job surviving.
#
# == Cadence
#
# Every 5 minutes, matching SpotCeilingSweepJob. A pass with nothing to do is one
# indexed query over the dormant queue; a pass with something to do re-arms at
# most SpotSessionHold::MAX_REARMS_PER_SWEEP sessions, spread over a few minutes
# so a recovered backlog does not hit the gate in one second. Combined with the
# OVERDUE_GRACE a stalled ladder is back inside ~15 minutes of its promised
# re-check, which is well under the ceilings the ladder itself climbs to.
class SpotHoldSweepJob < ApplicationJob
  include SingletonSweep

  def perform
    logger = StructuredLogger.new({ service: "SpotHoldSweepJob" })
    result = SpotSessionHold.sweep!(logger: logger)

    return if result.overdue.zero?

    logger.info("Spot hold sweep acted", **result.to_h)
  end
end
