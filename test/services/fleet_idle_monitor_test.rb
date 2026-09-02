# frozen_string_literal: true

require "test_helper"

# The latch that keeps "the fleet is quiet" from firing on every sweep.
#
# Idleness is a LEVEL, unlike the quota pool's rising edge, so the property these
# tests exist to pin is that the event fires ONCE per quiet stretch and cannot
# fire again until the fleet has work.
class FleetIdleMonitorTest < ActiveSupport::TestCase
  # Not included globally by test_helper — the enqueued SystemEventTriggerJob is
  # the whole observable outcome here.
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  setup do
    # The fixtures ship sessions in `running` and in `waiting`, which is exactly
    # the state this class reads. Every case states its own fleet.
    Session.delete_all
    AppSetting.editable.update!(fleet_idle_since: nil, fleet_idle_event_fired_at: nil,
                                quota_pool_available: true)
  end

  def session(status:, genesis: SessionGenesis::GITHUB_ISSUE, scheduling_class: nil, metadata: {})
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "work", genesis: genesis,
                    status: status, scheduling_class: scheduling_class,
                    session_id: "cli-#{SecureRandom.hex(4)}", metadata: metadata)
  end

  def setting
    AppSetting.current.reload
  end

  # The first observation has nothing to measure against, so it starts the clock
  # and fires nothing — the same reason QuotaAvailabilityMonitor treats its first
  # reading as a baseline.
  test "the first idle observation starts the clock and fires nothing" do
    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      assert_not FleetIdleMonitor.check!
    end

    assert_not_nil setting.fleet_idle_since
    assert_nil setting.fleet_idle_event_fired_at
  end

  test "an idle stretch shorter than the threshold fires nothing" do
    freeze_time do
      FleetIdleMonitor.check!

      travel FleetIdleMonitor::IDLE_THRESHOLD - 1.second
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
      assert_nil setting.fleet_idle_event_fired_at
    end
  end

  test "fires once the fleet has been idle for the whole threshold" do
    freeze_time do
      FleetIdleMonitor.check!

      travel FleetIdleMonitor::IDLE_THRESHOLD
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
      assert_not_nil setting.fleet_idle_event_fired_at
    end
  end

  # The regression this class exists for. A level-triggered implementation would
  # fire on this second check, and on every one after it, for as long as the
  # deployment stayed quiet.
  test "does not fire twice across consecutive checks with no session in between" do
    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD
      assert FleetIdleMonitor.check!

      travel 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end

      travel 1.hour
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
    end
  end

  test "re-arms once a session has run, and fires again on the next quiet stretch" do
    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD
      assert FleetIdleMonitor.check!

      # The status is written past the callbacks on purpose: this asserts the
      # SWEEP's own re-arm, which is the backstop for when the state-machine hook
      # never ran. The hook has its own test below.
      running = session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY)
      running.update_columns(status: Session.statuses[:running])

      travel 1.minute
      assert_not FleetIdleMonitor.check!
      assert_nil setting.fleet_idle_since, "a running session clears the idle clock"
      assert_not_nil setting.fleet_idle_event_fired_at,
        "the last-fire timestamp survives — it is the cooldown clock, not just the latch"

      running.update_columns(status: Session.statuses[:archived])
      travel 1.minute
      assert_not FleetIdleMonitor.check!, "the clock restarts rather than firing straight away"

      travel FleetIdleMonitor::MIN_FIRE_INTERVAL
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  test "a running session keeps the clock unset however long it runs" do
    session(status: :running)

    freeze_time do
      assert_not FleetIdleMonitor.check!
      travel 1.hour
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
      assert_nil setting.fleet_idle_since
    end
  end

  # A queued spot session is work the deployment already holds. Handing the
  # groomer more of it would deepen a queue rather than fill an idle fleet.
  test "a waiting spot session holds the event off" do
    session(status: :waiting, scheduling_class: SessionGenesis::SPOT)

    freeze_time do
      assert_not FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD + 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
      assert_nil setting.fleet_idle_since
    end
  end

  # Spot is also what a session's GENESIS resolves to when it named no class of
  # its own, and the queue is the same queue either way.
  test "a waiting session whose genesis classifies spot holds the event off" do
    spot_genesis = SessionGenesis.keys_classified(SessionGenesis::SPOT).first
    skip "no genesis kind defaults to spot" if spot_genesis.blank?

    session(status: :waiting, genesis: spot_genesis)

    freeze_time do
      assert_not FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD + 1.minute
      assert_not FleetIdleMonitor.check!
      assert_nil setting.fleet_idle_since
    end
  end

  # Priority work is never gated, so a priority session in `waiting` is one in
  # the seconds before its job picks it up rather than a queue.
  test "a waiting priority session does not hold the event off" do
    session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY)

    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  # Zimmer's own bookkeeping is not queued spot work, and one stranded in
  # `waiting` must not suppress the event forever.
  test "a waiting status-summary fork does not hold the event off" do
    session(status: :waiting, scheduling_class: SessionGenesis::SPOT,
            metadata: { SessionStatusSummaryGenerator::FORK_MARKER => "1" })

    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  # A session that starts and finishes between two sweeps is invisible to
  # sampling, so the state machine writes the fact directly. Without this the
  # latch would stay spent against a fleet that had gone back to work.
  test "a session entering running re-arms the latch through the state machine" do
    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD
      assert FleetIdleMonitor.check!
      assert_not_nil setting.fleet_idle_event_fired_at

      waiting = session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY)
      waiting.update!(status: :running)

      assert_nil setting.fleet_idle_since, "the idle clock is cleared, so the stretch is over"
    end
  end

  # The circular failure the cooldown exists for: the session this event spawns
  # runs, which re-arms the latch, which lets the event fire again five minutes
  # after it finishes — forever, on a deployment quiet for any other reason.
  test "the cooldown holds even when a session ran in between" do
    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD
      assert FleetIdleMonitor.check!

      # Stand in for the session the fire spawned: it runs, then finishes.
      spawned = session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY)
      spawned.update!(status: :running)
      travel 2.minutes
      spawned.update!(status: :archived)

      travel FleetIdleMonitor::IDLE_THRESHOLD + 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!,
          "the fleet went quiet again, but the hourly floor has not been spent"
      end

      travel FleetIdleMonitor::MIN_FIRE_INTERVAL
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  # An empty pool makes a quiet fleet a symptom, not an opportunity — and the
  # session this would spawn is priority, so it would start, find nothing to
  # serve, park, and have re-armed the latch on the way through.
  test "an account pool with nothing to serve holds the event off" do
    ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).update_all(status: :quota_exceeded)

    freeze_time do
      assert_not FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD + 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
      assert_nil AppSetting.current.reload.fleet_idle_since
    end
  end

  # A park is the clearest statement Zimmer makes that work exists and cannot
  # run, and an outage parks priority sessions too.
  test "a session parked on an auth outage holds the event off, whatever its class" do
    session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY,
            metadata: { "auth_outage_reason" => AuthOutageParkService::QUOTA_EXHAUSTED })

    freeze_time do
      assert_not FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD + 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
      assert_nil setting.fleet_idle_since
    end
  end

  # Nothing repairs an orphaned `running` row in a frozen category — both
  # recovery jobs skip them — so counting it would pin this to "busy" forever.
  test "a running session in a frozen category does not hold the event off" do
    frozen = Category.create!(name: "Frozen #{SecureRandom.hex(3)}", is_frozen: true)
    session(status: :running).update!(category: frozen)

    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  # A monitoring gap must not manufacture an idle fleet: the fire spawns a real
  # session.
  test "an unreadable fleet fires nothing and leaves the stored state alone" do
    FleetIdleMonitor.check!
    before = setting.fleet_idle_since

    Session.stub(:where, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
    end

    assert_equal before.to_i, setting.fleet_idle_since.to_i
    assert_nil setting.fleet_idle_event_fired_at, "nothing was fired, so nothing was recorded"
  end

  # The regression the latch decoupling exists to prevent. `quota_pool_available`
  # is an announcement latch, not a pool reading: QuotaAvailabilityMonitor holds
  # it at `false` through a recovery it has deferred because the spot gate is at
  # its utilization limit, which can last days. Reading it here would suppress the
  # idle event for all of that, on a spot-budget condition that says nothing about
  # the pool — and the session this spawns is priority and ungated, so it would
  # have run perfectly well.
  test "a deferred recovery does not hold the event off while the pool can serve" do
    AppSetting.editable.update!(quota_pool_available: false)
    assert ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).available.exists?,
      "the pool must be able to serve, so the latch is the only thing that could hold this off"

    freeze_time do
      assert_not FleetIdleMonitor.check!
      travel FleetIdleMonitor::IDLE_THRESHOLD + 1.minute
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end
end
