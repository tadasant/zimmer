# frozen_string_literal: true

# Refreshes the "$ per minute" of every harness + model combination.
#
# The spot gate multiplies these rates by "how long until I look again" to
# decide whether one more session fits inside the capacity left on the pacing
# curve. Computing them on the scheduling path would put an aggregate over the
# ledger in front of every spot session's start; this job puts it on a cron
# instead, and HarnessModelBurnRate is what the gate, the Costs page and
# `get_costs` read.
#
# Idempotent by construction: it recomputes every combination from scratch and
# upserts, so a second run in the same minute writes the same numbers. Nothing
# about it needs a shell on the box.
#
# Failures are swallowed. A missing refresh leaves the gate deciding on rates
# that are a little older, and HarnessModelBurnRate::FRESHNESS_HORIZON is what
# stops it trusting them forever if this job has genuinely stopped.
class BurnRateRecomputeJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  def perform
    count = BurnRateCalculator.recompute_all
    Rails.logger.info("[BurnRateRecomputeJob] Recomputed #{count} harness+model burn #{'rate'.pluralize(count)}")
    count
  rescue StandardError => e
    Rails.logger.warn("[BurnRateRecomputeJob] Recompute failed: #{e.class}: #{e.message}")
    nil
  end
end
