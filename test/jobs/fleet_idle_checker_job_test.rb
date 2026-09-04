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
    AppSetting.editable.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil,
                                quota_pool_available: true)
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

      travel FleetIdleMonitor.idle_threshold
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
      travel FleetIdleMonitor.idle_threshold

      assert_difference -> { Session.count }, 1 do
        perform_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }
      end
      session = Session.order(:id).last
    end

    assert_equal trigger.id.to_s, session.metadata["trigger_id"].to_s
    assert_includes session.prompt, "The fleet has room for more work"
    assert_equal SessionGenesis::SYSTEM_EVENT, session.genesis
    assert_not_nil trigger.trigger_conditions.first.reload.last_triggered_at
  end

  # The whole reason for the latch: an unattended deployment must not get one
  # groomer session per minute for as long as it stays quiet.
  test "a fleet that stays quiet spawns one session, not one per tick" do
    idle_trigger

    freeze_time do
      FleetIdleCheckerJob.perform_now
      travel FleetIdleMonitor.idle_threshold

      assert_difference -> { Session.count }, 1 do
        10.times do
          perform_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }
          travel 1.minute
        end
      end
    end
  end

  # The production case the test above does NOT reach: there, the spawned session
  # sits in `waiting` forever. In production it runs, and running is what re-arms
  # the latch — so without the cooldown the fleet would go quiet again five
  # minutes after it finished and the event would fire again, indefinitely.
  test "the session the event spawns cannot re-qualify the event by running" do
    idle_trigger

    freeze_time do
      FleetIdleCheckerJob.perform_now
      travel FleetIdleMonitor.idle_threshold
      perform_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }
      spawned = Session.order(:id).last

      assert_difference -> { Session.count }, 0 do
        # The spawned session works for ten minutes, finishes, and the fleet is
        # quiet again — three times over, well past IDLE_THRESHOLD each time.
        3.times do
          spawned.update!(status: :running)
          travel 10.minutes
          spawned.update!(status: :archived)

          6.times do
            perform_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }
            travel 1.minute
          end
        end
      end

      # Past the floor, a quiet fleet is a fresh opportunity again.
      travel FleetIdleMonitor.min_fire_interval
      assert_difference -> { Session.count }, 1 do
        perform_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }
      end
    end
  end
end
