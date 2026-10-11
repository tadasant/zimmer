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
    GoodJob::Job.where(job_class: "AgentSessionJob").delete_all
    # The quiet-backlog interval at 1 never binds below the cooldown, so the
    # cases here pin the cooldown; the reported empty-backlog loop sets it back.
    AppSetting.editable.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil,
                                quota_pool_available: true,
                                fleet_idle_quiet_backlog_interval_minutes: 1)
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

  # A session in `running` with a worker actually executing its turn — the only
  # population the ceiling counts. RunningTurns reads the `agents` job row rather
  # than `sessions.running_job_id`, which is written from inside `perform`.
  def running_session
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "work",
                    genesis: SessionGenesis::GITHUB_ISSUE, status: :running,
                    session_id: "cli-#{SecureRandom.hex(4)}")
  end

  def on_a_worker!(session)
    GoodJob::Job.create!(
      active_job_id: SecureRandom.uuid, queue_name: "agents", job_class: "AgentSessionJob",
      serialized_params: { "arguments" => [ session.id ] },
      scheduled_at: 2.minutes.ago, performed_at: 1.minute.ago
    )
    session
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

  # The whole reason for the cooldown: an unattended deployment must not get one
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
  # sits in `waiting` forever. In production it runs — and the cooldown is the
  # only thing standing between that and one session every five minutes, since
  # the idle stretch it fired inside never ended.
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

  # The reported deployment, end to end: a ceiling of 12 the fleet never comes
  # near, four turns on a worker, and sessions entering `running` throughout. The
  # clock stays anchored to the crossing, so top-up runs at the CONFIGURED
  # cadence — one groomer per cooldown — rather than at the mercy of gaps between
  # session starts.
  test "a fleet steady well under a high ceiling tops up on the configured cadence" do
    AppSetting.editable.update!(fleet_idle_max_sessions: 12)
    idle_trigger

    # Four turns actually on a worker, which is what the ceiling counts — the
    # reported fleet's shape rather than four rows that read `running`.
    fleet = Array.new(4) { on_a_worker!(running_session) }

    freeze_time do
      FleetIdleCheckerJob.perform_now
      crossing = AppSetting.current.reload.fleet_idle_since
      assert_equal 4, FleetIdleMonitor.running_sessions

      # Three hours of a fleet that is always busy and never full: every ten
      # minutes one turn ends and another starts, holding it at four, and one
      # fire an hour.
      assert_difference -> { Session.where(genesis: SessionGenesis::SYSTEM_EVENT).count }, 3 do
        18.times do |i|
          travel 10.minutes
          fleet[i % 4].update!(status: :archived)
          fleet[i % 4] = on_a_worker!(running_session)
          assert_equal 4, FleetIdleMonitor.running_sessions, "the fleet stays at four on a worker"
          perform_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }
        end
      end

      assert_equal crossing.to_i, AppSetting.current.reload.fleet_idle_since.to_i,
        "nothing crossed the ceiling of 12, so nothing moved the clock"
    end
  end

  # The loop the board showed, end to end: trigger 13507 on an idle fleet with an
  # empty backlog and a 10-minute cooldown. Each top-up runs two minutes, finds
  # nothing to pull and archives, and the event fired again ten minutes later —
  # ~130 sessions a day. With the quiet-backlog interval it is one per four
  # hours, and a newly queued item is still picked up at the next check.
  test "an idle fleet with an empty backlog no longer polls itself every cooldown" do
    WorkBacklogItem.delete_all
    AppSetting.editable.update!(fleet_idle_min_fire_interval_minutes: 10,
                                fleet_idle_quiet_backlog_interval_minutes:
                                  AppSetting::DEFAULT_FLEET_IDLE_QUIET_BACKLOG_INTERVAL_MINUTES)
    idle_trigger(skip_if_pending_session: true)
    spawned = -> { Session.where(genesis: SessionGenesis::SYSTEM_EVENT) }

    freeze_time do
      FleetIdleCheckerJob.perform_now

      assert_difference -> { spawned.call.count }, 6 do
        (24 * 60).times do
          travel 1.minute
          # Each top-up runs for two minutes on a worker and then archives,
          # having found nothing to pull.
          spawned.call.where(status: :waiting).find_each { |s| on_a_worker!(s).update!(status: :running) }
          spawned.call.where(status: :running).where(updated_at: ..2.minutes.ago).find_each do |s|
            s.update!(status: :archived)
          end
          perform_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }
        end
      end

      # Work arrives on the backlog: the next check past the cooldown hands it
      # out rather than waiting for the rest of the four hours.
      travel 15.minutes
      spawned.call.where.not(status: :archived).find_each { |s| s.update!(status: :archived) }
      WorkBacklogItem.create!(
        key: "zimmer#1", issue_url: "https://github.com/tadasant/zimmer/issues/1", repo: "tadasant/zimmer",
        surface: "zimmer", title: "New work", kind: "bug", scope_direction: "convergent",
        estimated_cost: "small", gate_verdict: "auto-proceed", decided_at: Date.current,
        added_at: Time.current, added_by: "issue-work-gate", added_via: WorkBacklogItem::MCP,
        precedence: WorkBacklog::Ranking.band_for("small").base, status: WorkBacklogItem::QUEUED
      )
      assert_difference -> { spawned.call.count }, 1 do
        perform_enqueued_jobs(only: SystemEventTriggerJob) { FleetIdleCheckerJob.perform_now }
      end
    end
  end
end
