# frozen_string_literal: true

# Announces a trigger fire whose session died holding the work. All of the
# judgement lives in OrphanedTriggerFire; this job exists only to get the work out
# of the `fail` transition's own transaction — AASM runs `after` callbacks inside
# it, and the report reads the session's metadata and writes a timeline entry.
#
# `default`, not `maintenance`. The alert's whole value is that a dropped work
# item is seen in minutes rather than in hours, and `maintenance` is the lane
# that exists to hold multi-minute filesystem sweeps — a job queued behind
# `OrphanCloneFilesystemCleanupJob` can wait most of an hour. This does one
# `find_by`, one UPDATE and one INSERT, which is the shape the deterministic
# `SendPushNotificationJob` types keep on `default` too.
class OrphanedTriggerFireJob < ApplicationJob
  queue_as :default

  def perform(session_id)
    session = Session.find_by(id: session_id)
    return if session.nil?

    OrphanedTriggerFire.report!(session)
  end
end
