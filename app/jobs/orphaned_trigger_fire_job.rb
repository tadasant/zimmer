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
class OrphanedTriggerFireJob < ApplicationJob
  queue_as :maintenance

  def perform(session_id)
    session = Session.find_by(id: session_id)
    return if session.nil?

    OrphanedTriggerFire.report!(session)
  end
end
