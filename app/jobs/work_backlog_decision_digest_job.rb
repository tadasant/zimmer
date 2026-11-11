# frozen_string_literal: true

# Sends the owner the decisions the work backlog is waiting on, and renews the
# holds a delivery covered. WorkBacklog::DecisionDigest says why that pairing is
# what keeps this from being a silence.
#
# DAILY, though a decision is only re-sent every WorkBacklog::DecisionDigest::CADENCE.
# The tick is what bounds how long a new hold waits to reach its owner, and how
# soon a failed delivery is tried again.
#
# Production and staging, like every other cron entry. Staging has no device
# subscribed, so a hold there logs the failed delivery, and the error-log rule does
# not count staging.
#
# On `default`, not `pollers`: a digest that cannot run is noticed by its holds
# lapsing into WorkBacklogLivenessSweepJob's page on `pollers`, and these two
# should not share a worker's fate.
class WorkBacklogDecisionDigestJob < ApplicationJob
  include SingletonSweep

  queue_as :default

  def perform
    WorkBacklog::DecisionDigest.deliver!
  end
end
