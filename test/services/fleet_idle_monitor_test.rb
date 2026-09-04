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
                                quota_pool_available: true,
                                fleet_idle_max_sessions: AppSetting::DEFAULT_FLEET_IDLE_MAX_SESSIONS,
                                fleet_idle_threshold_minutes: AppSetting::DEFAULT_FLEET_IDLE_THRESHOLD_MINUTES,
                                fleet_idle_min_fire_interval_minutes: AppSetting::DEFAULT_FLEET_IDLE_MIN_FIRE_INTERVAL_MINUTES)
  end

  # A ceiling of 1 is the pair of booleans the threshold replaced — nothing
  # running and nothing queued — so the cases that pin one session's effect on
  # the event set it, and say so by calling this.
  def ceiling(count)
    AppSetting.editable.update!(fleet_idle_max_sessions: count)
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

      travel FleetIdleMonitor.idle_threshold - 1.second
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
      assert_nil setting.fleet_idle_event_fired_at
    end
  end

  test "fires once the fleet has been idle for the whole threshold" do
    freeze_time do
      FleetIdleMonitor.check!

      travel FleetIdleMonitor.idle_threshold
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
      travel FleetIdleMonitor.idle_threshold
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
      travel FleetIdleMonitor.idle_threshold
      assert FleetIdleMonitor.check!

      # The status is written past the callbacks on purpose: this asserts the
      # SWEEP's own re-arm, which is the backstop for when the state-machine hook
      # never ran. The hook has its own test below. Enough of them to reach the
      # ceiling, since that is what the sweep reads.
      running = Array.new(3) { session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY) }
      running.each { |s| s.update_columns(status: Session.statuses[:running]) }

      travel 1.minute
      assert_not FleetIdleMonitor.check!
      assert_nil setting.fleet_idle_since, "a fleet at its ceiling clears the idle clock"
      assert_not_nil setting.fleet_idle_event_fired_at,
        "the last-fire timestamp survives — it is the cooldown clock, not just the latch"

      running.each { |s| s.update_columns(status: Session.statuses[:archived]) }
      travel 1.minute
      assert_not FleetIdleMonitor.check!, "the clock restarts rather than firing straight away"

      travel FleetIdleMonitor.min_fire_interval
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  test "a running session keeps the clock unset however long it runs, at a ceiling of one" do
    ceiling(1)
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

  # A queued spot session is work the deployment already holds, so it counts
  # toward the same ceiling a running one does. At a ceiling of 1 that is the old
  # boolean exactly: one queued spot session is enough.
  test "a waiting spot session holds the event off at a ceiling of one" do
    ceiling(1)
    session(status: :waiting, scheduling_class: SessionGenesis::SPOT)

    freeze_time do
      assert_not FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold + 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
      assert_nil setting.fleet_idle_since
    end
  end

  # Spot is also what a session's GENESIS resolves to when it named no class of
  # its own, and the queue is the same queue either way.
  test "a waiting session whose genesis classifies spot holds the event off at a ceiling of one" do
    ceiling(1)
    spot_genesis = SessionGenesis.keys_classified(SessionGenesis::SPOT).first
    skip "no genesis kind defaults to spot" if spot_genesis.blank?

    session(status: :waiting, genesis: spot_genesis)

    freeze_time do
      assert_not FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold + 1.minute
      assert_not FleetIdleMonitor.check!
      assert_nil setting.fleet_idle_since
    end
  end

  # Priority work is never gated, so a priority session in `waiting` is one in
  # the seconds before its job picks it up rather than a queue.
  test "a waiting priority session does not hold the event off" do
    ceiling(1)
    session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY)

    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  # Zimmer's own bookkeeping is not queued spot work, and one stranded in
  # `waiting` must not suppress the event forever.
  test "a waiting status-summary fork does not hold the event off" do
    ceiling(1)
    session(status: :waiting, scheduling_class: SessionGenesis::SPOT,
            metadata: { SessionStatusSummaryGenerator::FORK_MARKER => "1" })

    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold
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
      travel FleetIdleMonitor.idle_threshold
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
      travel FleetIdleMonitor.idle_threshold
      assert FleetIdleMonitor.check!

      # Stand in for the session the fire spawned: it runs, then finishes.
      spawned = session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY)
      spawned.update!(status: :running)
      travel 2.minutes
      spawned.update!(status: :archived)

      travel FleetIdleMonitor.idle_threshold + 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!,
          "the fleet went quiet again, but the hourly floor has not been spent"
      end

      travel FleetIdleMonitor.min_fire_interval
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
      travel FleetIdleMonitor.idle_threshold + 1.minute
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
      travel FleetIdleMonitor.idle_threshold + 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
      assert_nil setting.fleet_idle_since
    end
  end

  # Nothing repairs an orphaned `running` row in a frozen category — both
  # recovery jobs skip them — so counting it would pin this to "busy" forever.
  test "a running session in a frozen category does not hold the event off" do
    ceiling(1)
    frozen = Category.create!(name: "Frozen #{SecureRandom.hex(3)}", is_frozen: true)
    session(status: :running).update!(category: frozen)

    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold
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
      travel FleetIdleMonitor.idle_threshold + 1.minute
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The ceiling
  # ---------------------------------------------------------------------------

  # The change this class exists for after the boolean. A fleet with two of ten
  # slots filled has capacity nobody is using, and used to have to reach zero
  # before it would be topped up.
  test "fires with sessions still running, as long as the fleet is under its ceiling" do
    2.times { session(status: :running) }

    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  test "a fleet at its ceiling is not idle" do
    3.times { session(status: :running) }

    freeze_time do
      assert_not FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold + 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end
      assert_nil setting.fleet_idle_since
    end
  end

  # One ceiling over two populations, which is the answer to a spot queue that
  # used to veto on its own however much room the fleet had.
  test "running and queued spot sessions are counted against the same ceiling" do
    2.times { session(status: :running) }
    session(status: :waiting, scheduling_class: SessionGenesis::SPOT)

    freeze_time do
      assert_not FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold + 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!, "two running plus one queued reaches a ceiling of three"
      end
    end
  end

  # The other half of the same point: a spot queue no longer vetoes on its own.
  # The fleet has room, and the session this spawns is priority and ungated.
  test "a single queued spot session does not hold the event off under a ceiling above one" do
    session(status: :waiting, scheduling_class: SessionGenesis::SPOT)

    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  test "raising the ceiling makes a fleet that was busy count as idle" do
    3.times { session(status: :running) }

    freeze_time do
      assert_not FleetIdleMonitor.check!
      assert_nil setting.fleet_idle_since

      ceiling(5)
      assert_not FleetIdleMonitor.check!, "the clock starts on this pass rather than firing"
      travel FleetIdleMonitor.idle_threshold
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The latch and the cooldown under a ceiling
  # ---------------------------------------------------------------------------

  # The reason the cooldown gets more load-bearing, not less, once the ceiling is
  # above 1: the session the fire spawns no longer takes the fleet out of its own
  # idle window, so the stretch does not end when it starts running.
  test "the cooldown holds while the session the fire spawned is still running" do
    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold
      assert FleetIdleMonitor.check!

      # Stand in for the session the fire spawned. It runs and keeps running, and
      # one running session leaves the fleet under a ceiling of three.
      spawned = session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY)
      spawned.update!(status: :running)
      assert_nil setting.fleet_idle_since,
        "the state-machine hook ends the stretch even though the fleet is still under its ceiling"

      travel FleetIdleMonitor.idle_threshold + 1.minute
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!,
          "the fleet is idle enough again, but the cooldown has not been spent"
      end

      travel FleetIdleMonitor.min_fire_interval
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  # Without a re-arm the latch would hold forever on a fleet that never climbs
  # above its ceiling, and the event would fire exactly once in the deployment's
  # life. `record_busy!` is unconditional for this reason.
  test "the latch is re-armed by a session running even when the fleet stays under its ceiling" do
    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold
      assert FleetIdleMonitor.check!
      fired_at = setting.fleet_idle_event_fired_at

      travel 1.minute
      session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY).update!(status: :running)
      assert_nil setting.fleet_idle_since

      travel 1.minute
      assert_not FleetIdleMonitor.check!
      assert setting.fleet_idle_since > fired_at,
        "the new stretch starts after the last fire, so the latch is open and the cooldown decides"
    end
  end

  # ---------------------------------------------------------------------------
  # The other two knobs
  # ---------------------------------------------------------------------------

  test "the idle threshold is read from the settings row" do
    AppSetting.editable.update!(fleet_idle_threshold_minutes: 30)

    freeze_time do
      FleetIdleMonitor.check!
      travel 29.minutes
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not FleetIdleMonitor.check!
      end

      travel 1.minute
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  # The knob that actually sets top-up frequency once the ceiling stops being the
  # binding term.
  test "the cooldown is read from the settings row" do
    AppSetting.editable.update!(fleet_idle_min_fire_interval_minutes: 10)

    freeze_time do
      FleetIdleMonitor.check!
      travel FleetIdleMonitor.idle_threshold
      assert FleetIdleMonitor.check!

      session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY).update!(status: :running)
      travel FleetIdleMonitor.idle_threshold + 1.minute
      assert_not FleetIdleMonitor.check!, "six minutes into a ten-minute cooldown"

      travel 5.minutes
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "no_sessions_in_progress" ]) do
        assert FleetIdleMonitor.check!
      end
    end
  end

  test "sessions_in_hand counts running and queued spot sessions, and nothing else" do
    2.times { session(status: :running) }
    session(status: :waiting, scheduling_class: SessionGenesis::SPOT)
    session(status: :waiting, scheduling_class: SessionGenesis::PRIORITY)
    session(status: :archived)

    assert_equal 3, FleetIdleMonitor.sessions_in_hand
  end
end
