# frozen_string_literal: true

require "test_helper"

# The cron entry, and the path from "the fleet went quiet" to a session on the
# trigger that listens for it.
class FleetIdleCheckerJobTest < ActiveJob::TestCase
  include ActiveSupport::Testing::TimeHelpers

  setup do
    # The fixtures ship sessions in `running` and in `waiting`, which is exactly
    # what the monitor reads.
    Session.delete_all
    AppSetting.editable.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil)
  end

  def idle_trigger(status: "enabled", skip_if_pending_session: false)
    Trigger.create!(
      name: "Idle fleet groomer #{SecureRandom.hex(3)}",
      agent_root_name: AgentRootsConfig.all.first.name,
      prompt_template: "Groom the backlog: {{event}}",
      status: status,
      skip_if_pending_session: skip_if_pending_session,
      scheduling_class: SessionGenesis::PRIORITY,
      trigger_conditions_attributes: [
        { condition_type: "system_event",
          configuration: { "event_name" => FleetIdleMonitor::EVENT_NAME } }
      ]
    )
  end

  test "a quiet fleet enqueues the event once the threshold is crossed" do
    freeze_time do
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }

      travel FleetIdleMonitor::IDLE_THRESHOLD
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ FleetIdleMonitor::EVENT_NAME ]) do
        FleetIdleCheckerJob.perform_now
      end
    end
  end

  # End to end: idle fleet -> event -> the trigger listening for it -> a session
  # carrying that trigger's prompt.
  test "the event a quiet fleet raises reaches a trigger listening for it" do
    trigger = idle_trigger

    session = nil
    freeze_time do
      FleetIdleCheckerJob.perform_now
      travel FleetIdleMonitor::IDLE_THRESHOLD

      assert_difference -> { Session.count }, 1 do
        perform_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }
      end
      session = Session.order(:id).last
    end

    assert_equal trigger.id.to_s, session.metadata["trigger_id"].to_s
    assert_includes session.prompt, "no sessions running"
    assert_equal SessionGenesis::SYSTEM_EVENT, session.genesis
    assert_not_nil trigger.trigger_conditions.first.reload.last_triggered_at
  end

  # The whole reason for the latch: an unattended deployment must not get one
  # groomer session per minute for as long as it stays quiet.
  test "a fleet that stays quiet spawns one session, not one per tick" do
    idle_trigger

    freeze_time do
      FleetIdleCheckerJob.perform_now
      travel FleetIdleMonitor::IDLE_THRESHOLD

      assert_difference -> { Session.count }, 1 do
        10.times do
          perform_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }
          travel 1.minute
        end
      end
    end
  end
end
