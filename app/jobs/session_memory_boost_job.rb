# frozen_string_literal: true

# Converges the worker's memory cgroups on the one-off memory boosts the database holds —
# carve a boosted session out of the shared tier, cap everyone else, and undo both once
# the boost expires, is cleared, or its session is archived. SessionMemoryBoost has the
# design; this is only the clock.
#
# Every minute, because a boost is usually asked for in the middle of the turn that needs
# it, and because the cap on everyone else ratchets down a step per run as they free
# memory. A run with no boost held and none to undo costs one indexed query and a few
# file reads, and a container without session cgroups (the web role, a dev machine) is a
# no-op.
class SessionMemoryBoostJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  def perform
    granted = SessionMemoryBoost.reconcile!
    return if granted.empty?

    Rails.logger.info "[SessionMemoryBoostJob] In force: " +
      granted.map { |id, bytes| "session #{id} at #{bytes} bytes" }.join(", ")
  end
end
