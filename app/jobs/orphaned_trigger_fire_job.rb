# frozen_string_literal: true

# Announces a trigger fire whose session died holding the work. All of the
# judgement lives in OrphanedTriggerFire; this job exists only to get the Slack
# round trip out of the `fail` transition's own transaction.
#
# That is the same reason `SessionStateMachine#report_swallowed_side_effect`
# defers its alert past commit: AASM runs `after` callbacks inside the
# transition's transaction, and AlertService posts synchronously (5s connect /
# 10s read). Alerting inline would hold a transaction open on the session row for
# a network round trip during exactly the incident where that hurts most.
#
# `default`, not `maintenance`. The alert's whole value is that a dropped work
# item is seen in minutes rather than in hours, and `maintenance` is the lane
# that exists to hold multi-minute filesystem sweeps — a job queued behind
# `OrphanCloneFilesystemCleanupJob` can wait most of an hour. This does one
# `find_by`, one UPDATE, one INSERT and one Slack post, which is the shape the
# deterministic `SendPushNotificationJob` types keep on `default` too.
class OrphanedTriggerFireJob < ApplicationJob
  queue_as :default

  def perform(session_id)
    session = Session.find_by(id: session_id)
    return if session.nil?

    OrphanedTriggerFire.report!(session)
  end
end
