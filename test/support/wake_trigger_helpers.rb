# frozen_string_literal: true

# Arming a self-scheduled wake against a session, for the tests that care what a
# sleeping session does to a count or a sweep.
#
# Every one of them wants the same thing: a one-time `schedule` condition on a
# `reuse_session` trigger pointed at the session, for a time that has not come.
# Building it through `Trigger.new(...).save!` rather than the MCP tool is what
# keeps the after_create hooks — which would put the session to sleep, or fire
# the trigger outright — from running underneath the case being pinned.
#
# Usage:
#   arm_wake!(session, at: 20.minutes.from_now)   # asleep
#   arm_wake!(session, at: 5.minutes.ago)         # due, so no longer a pause
module WakeTriggerHelpers
  # @param session [Session] the session the wake targets
  # @param at [ActiveSupport::TimeWithZone, Time] when it fires
  # @return [Trigger]
  def arm_wake!(session, at:)
    trigger = Trigger.new(
      name: "Wake session ##{session.id}",
      status: "enabled",
      agent_root_name: "zimmer",
      prompt_template: "wake up",
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        { condition_type: "schedule",
          configuration: { "scheduled_at" => at.utc.strftime("%Y-%m-%dT%H:%M:%S"), "timezone" => "UTC" } }
      ]
    )
    trigger.save!(validate: true)
    trigger
  end
end

class ActiveSupport::TestCase
  include WakeTriggerHelpers
end
