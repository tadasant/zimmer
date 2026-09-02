# frozen_string_literal: true

require "test_helper"

# The edge that replaced a timer per parked session: quota-full to
# quota-available, fired once per recovery.
class QuotaAvailabilityMonitorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ClaudeAccountQuotaSnapshot.delete_all
    ClaudeAccount.delete_all
    AppSetting.current.update!(quota_pool_available: nil, quota_pool_available_changed_at: nil)
  end

  def account(status)
    ClaudeAccount.create!(email: "a-#{SecureRandom.hex(4)}@example.com", status: status,
      runtime: "claude_code", oauth_config: { "credentials_json" => { "token" => "x" } })
  end

  # A deploy landing while the pool happens to be healthy is not a recovery. The
  # first observation records the level and fires nothing.
  test "the first observation is a baseline, not a transition" do
    account(:active)

    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      assert_not QuotaAvailabilityMonitor.check!
    end
    assert_equal true, AppSetting.current.reload.quota_pool_available
  end

  test "fires the event when the pool goes from serving nothing to serving something" do
    exceeded = account(:quota_exceeded)
    QuotaAvailabilityMonitor.check!
    assert_equal false, AppSetting.current.reload.quota_pool_available

    exceeded.update!(status: :active)

    assert_enqueued_with(job: SystemEventTriggerJob, args: [ "quota_available" ]) do
      assert QuotaAvailabilityMonitor.check!
    end
    assert_equal true, AppSetting.current.reload.quota_pool_available
  end

  # A level would fire on every sweep for as long as the pool stayed healthy,
  # spawning a fleet session every fifteen minutes.
  test "a pool that was already available fires nothing" do
    account(:active)
    QuotaAvailabilityMonitor.check!

    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      assert_not QuotaAvailabilityMonitor.check!
    end
  end

  test "the pool falling over records the level and fires nothing" do
    live = account(:active)
    QuotaAvailabilityMonitor.check!

    live.update!(status: :quota_exceeded)

    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      assert_not QuotaAvailabilityMonitor.check!
    end
    assert_equal false, AppSetting.current.reload.quota_pool_available
  end

  # The failure the 15-minute sampling alone cannot see: an outage that opens and
  # closes inside one tick is never observed as unavailable, so the recovery is
  # not an edge and everything parked in that window waits forever.
  test "a park records the pool as unavailable, so the recovery is a real edge" do
    account(:active)
    QuotaAvailabilityMonitor.check!
    assert_equal true, AppSetting.current.reload.quota_pool_available

    assert QuotaAvailabilityMonitor.record_unavailable!
    assert_equal false, AppSetting.current.reload.quota_pool_available

    assert_enqueued_with(job: SystemEventTriggerJob, args: [ "quota_available" ]) do
      assert QuotaAvailabilityMonitor.check!
    end
  end

  test "recording the pool unavailable twice is a no-op" do
    QuotaAvailabilityMonitor.record_unavailable!

    assert_not QuotaAvailabilityMonitor.record_unavailable!
  end

  # The edge is the only thing that fires the wake, so it must not be spent on a
  # fire nobody acted on — nothing else re-arms it.
  test "re-arming puts the edge back" do
    account(:active)
    QuotaAvailabilityMonitor.check!
    assert_equal true, AppSetting.current.reload.quota_pool_available

    assert QuotaAvailabilityMonitor.rearm!
    assert_equal false, AppSetting.current.reload.quota_pool_available
  end

  test "re-arming an already-armed edge is a no-op" do
    QuotaAvailabilityMonitor.record_unavailable!

    assert_not QuotaAvailabilityMonitor.rearm!
  end

  # A parked spot session can become eligible on evidence the pool edge does not
  # carry — an auth park whose credentials changed. Firing on request is its only
  # wake path.
  test "request_wake! fires when the edge has not been spent" do
    QuotaAvailabilityMonitor.record_unavailable!

    assert_enqueued_with(job: SystemEventTriggerJob, args: [ "quota_available" ]) do
      assert QuotaAvailabilityMonitor.request_wake!(reason: "test")
    end
    assert_equal true, AppSetting.current.reload.quota_pool_available
  end

  # ...but it must not spawn a fleet session every fifteen minutes for as long as
  # one session stays parked.
  test "request_wake! is a no-op once the edge has been spent" do
    account(:active)
    QuotaAvailabilityMonitor.check!

    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      assert_not QuotaAvailabilityMonitor.request_wake!(reason: "test")
    end
    assert_equal true, AppSetting.current.reload.quota_pool_available,
      "the level stays spent — re-arming here is what made the next check! fire again"
  end

  # The loop this guards: `check!` and the sweep that calls `request_wake!` run in
  # the SAME fifteen-minute pass. If a spent request re-armed the edge, the next
  # pass would see false→true against a pool that never left, fire again, and
  # keep firing for as long as one session stayed parked — each fire a real
  # session burning the quota that just recovered.
  test "a still-parked session does not make every later pass fire again" do
    account(:active)

    QuotaAvailabilityMonitor.record_unavailable!
    assert QuotaAvailabilityMonitor.check!, "the first pass fires"
    QuotaAvailabilityMonitor.request_wake!(reason: "still parked")

    3.times do |pass|
      assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
        assert_not QuotaAvailabilityMonitor.check!, "pass #{pass + 2} must not re-fire"
        assert_not QuotaAvailabilityMonitor.request_wake!(reason: "still parked")
      end
    end
  end

  # One global column, one monitored pool: a Codex park must not arm an edge that
  # is only ever read against the Claude pool.
  test "only the monitored runtime's park records the pool as unavailable" do
    account(:active)
    QuotaAvailabilityMonitor.check!

    assert_not QuotaAvailabilityMonitor.record_unavailable!(runtime: "codex")
    assert_equal true, AppSetting.current.reload.quota_pool_available

    assert QuotaAvailabilityMonitor.record_unavailable!(runtime: ClaudeAuthProvider::RUNTIME)
    assert_equal false, AppSetting.current.reload.quota_pool_available
  end

  # An unreadable pool must not be recorded as an outage: the next successful
  # read would then fire a recovery nothing recovered from.
  test "a pool that cannot be read leaves the stored level alone" do
    account(:active)
    QuotaAvailabilityMonitor.check!

    QuotaAvailabilityMonitor.stub(:pool_available?, nil) do
      assert_not QuotaAvailabilityMonitor.check!
    end

    assert_equal true, AppSetting.current.reload.quota_pool_available
  end

  # ===========================================================================
  # The spot gate decides whether the recovery is worth announcing (#611)
  #
  # The pool's `status` column and the spot gate answer different questions and
  # can disagree for days: an account goes back to `available` when Anthropic's
  # own window clears, while the gate compares the pool's spend against the
  # operator's reserve and pacing curve. On 2026-08-22 that disagreement fired
  # the "the pool has capacity again" edge 27 times in ten hours, every one of
  # them spawning a `priority` fleet session that read `HELD` and woke nobody.
  # ===========================================================================

  # The gate averages every account's latest snapshot and counts every running
  # session, so a fixture reading or a fixture session in `running` would decide
  # these tests instead of the seeds below.
  def enable_spot_gating(reserve_pct: 20, max_concurrent: 10)
    Session.where(status: :running).update_all(status: Session.statuses[:needs_input])
    AppSetting.editable.update!(spot_gating_enabled: true,
                                spot_reserve_five_hour_pct: reserve_pct,
                                spot_reserve_weekly_pct: reserve_pct,
                                spot_max_concurrent_sessions: max_concurrent)
  end

  def seed_reading(account, utilization_5h:, utilization_7d:)
    ClaudeAccountQuotaSnapshot.create!(
      claude_account: account,
      utilization_5h: utilization_5h, utilization_7d: utilization_7d,
      reset_5h: 2.hours.from_now, reset_7d: 2.days.from_now,
      active_session_count: 1, trigger: "usage_sample"
    )
  end

  # The reproduction, in the shape the 2026-08-22T18:12:59Z report describes: the
  # per-account quota flag has cleared, so `accounts.available` reads true and the
  # pool edge rises — while the pool's aggregate utilization is still far past the
  # share spot work is allowed to touch, so the gate the woken session reads is
  # HELD. Before the gate check this fired, and the fleet session it spawned woke
  # nothing.
  test "the edge does not fire while the spot gate is holding spot work" do
    enable_spot_gating
    exceeded = account(:quota_exceeded)
    seed_reading(exceeded, utilization_5h: 0.89, utilization_7d: 0.93)
    QuotaAvailabilityMonitor.check!
    assert_equal false, AppSetting.current.reload.quota_pool_available

    # What QuotaResetCheckerJob does when Anthropic's own window clears: the
    # per-account label goes, the aggregate utilization does not.
    exceeded.update!(status: :active)
    assert SpotGateService.evaluate.held?, "the fixture must reproduce a held gate"

    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      assert_not QuotaAvailabilityMonitor.check!
    end
    assert_equal false, AppSetting.current.reload.quota_pool_available,
      "the edge is DEFERRED, not spent — the next sweep has to be able to fire it"
  end

  # The recurrence rate is the cost: `check!` runs every fifteen minutes, and
  # every pass through an over-target window used to be another priority session
  # that read HELD and woke nobody.
  test "a pool held by the gate does not fire once per sweep" do
    enable_spot_gating
    held = account(:quota_exceeded)
    seed_reading(held, utilization_5h: 0.89, utilization_7d: 0.93)
    QuotaAvailabilityMonitor.check!
    held.update!(status: :active)

    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      4.times { |pass| assert_not QuotaAvailabilityMonitor.check!, "sweep #{pass + 1} must not fire" }
    end
  end

  # The regression the deferral must not become: an edge that can never fire
  # again leaves every parked session asleep forever, which is worse than the
  # noise it replaced. The same pool, once the gate opens, fires on the very
  # next sweep.
  test "the deferred edge fires as soon as the gate opens" do
    enable_spot_gating
    recovering = account(:quota_exceeded)
    reading = seed_reading(recovering, utilization_5h: 0.89, utilization_7d: 0.93)
    QuotaAvailabilityMonitor.check!
    recovering.update!(status: :active)
    assert_not QuotaAvailabilityMonitor.check!

    # The window rolls over: the same pool, now inside the share spot work owns.
    reading.update!(utilization_5h: 0.10, utilization_7d: 0.10)
    assert SpotGateService.evaluate.allowed?, "the fixture must reproduce an open gate"

    assert_enqueued_with(job: SystemEventTriggerJob, args: [ "quota_available" ]) do
      assert QuotaAvailabilityMonitor.check!
    end
    assert_equal true, AppSetting.current.reload.quota_pool_available
  end

  # A genuine recovery with the gate consulted and open still fires, which is the
  # whole point of the event.
  test "a real recovery fires while the gate has room" do
    enable_spot_gating
    exceeded = account(:quota_exceeded)
    seed_reading(exceeded, utilization_5h: 0.10, utilization_7d: 0.10)
    QuotaAvailabilityMonitor.check!
    assert_equal false, AppSetting.current.reload.quota_pool_available

    exceeded.update!(status: :active)

    assert_enqueued_with(job: SystemEventTriggerJob, args: [ "quota_available" ]) do
      assert QuotaAvailabilityMonitor.check!
    end
  end

  # A full fleet is NOT a reason to defer, and the asymmetry is the point. A
  # window's hold moves on the window's clock, which is slower than this
  # fifteen-minute sweep; cap contention moves on a session's clock, which is far
  # faster. Deferring on the cap would let a fleet that habitually runs at its
  # cap show `fleet_at_cap` to every sweep while ordinary held spot sessions took
  # the freed slots on their own ten-minute ladder — starving the outage-parked
  # sessions whose only wake path this is.
  test "a full fleet is not a reason to defer the edge" do
    enable_spot_gating(max_concurrent: 1)
    exceeded = account(:quota_exceeded)
    seed_reading(exceeded, utilization_5h: 0.10, utilization_7d: 0.10)
    QuotaAvailabilityMonitor.check!
    exceeded.update!(status: :active)
    Session.create!(prompt: "occupying the only slot", agent_runtime: "claude_code", status: :running,
      git_root: "https://github.com/test/repo.git", branch: "main",
      execution_provider: "local_filesystem", session_id: SecureRandom.uuid)

    assert_equal SpotGateService::FLEET_CAP_REASON, SpotGateService.evaluate.reason,
      "the fixture must reproduce a gate held on the cap rather than on a window"

    assert_enqueued_with(job: SystemEventTriggerJob, args: [ "quota_available" ]) do
      assert QuotaAvailabilityMonitor.check!
    end
  end

  # Fail OPEN. A gate that cannot be read must not become an outage of the only
  # wake path a parked spot session has — the fleet session re-reads the gate for
  # itself, so a spurious fire costs one session while a suppressed one costs
  # every parked session indefinitely.
  test "a spot gate that cannot be read fires the edge anyway" do
    exceeded = account(:quota_exceeded)
    QuotaAvailabilityMonitor.check!
    exceeded.update!(status: :active)

    SpotGateService.stub(:evaluate, ->(*) { raise "gate is down" }) do
      assert_enqueued_with(job: SystemEventTriggerJob, args: [ "quota_available" ]) do
        assert QuotaAvailabilityMonitor.check!
      end
    end
  end

  # request_wake! fires the same event, to be answered by the same fleet session,
  # so it asks the same question. Its caller sweeps every fifteen minutes and
  # asks again, so a deferral costs one sweep and no edge.
  test "request_wake! defers while the gate is holding and fires once it opens" do
    enable_spot_gating
    held = account(:active)
    reading = seed_reading(held, utilization_5h: 0.89, utilization_7d: 0.93)
    QuotaAvailabilityMonitor.record_unavailable!

    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      assert_not QuotaAvailabilityMonitor.request_wake!(reason: "1 parked spot session")
    end
    assert_equal false, AppSetting.current.reload.quota_pool_available

    reading.update!(utilization_5h: 0.10, utilization_7d: 0.10)

    assert_enqueued_with(job: SystemEventTriggerJob, args: [ "quota_available" ]) do
      assert QuotaAvailabilityMonitor.request_wake!(reason: "1 parked spot session")
    end
  end
end
