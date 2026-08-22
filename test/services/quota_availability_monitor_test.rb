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
  test "request_wake! re-arms rather than firing twice for one recovery" do
    account(:active)
    QuotaAvailabilityMonitor.check!

    assert_no_enqueued_jobs(only: SystemEventTriggerJob) do
      assert_not QuotaAvailabilityMonitor.request_wake!(reason: "test")
    end
    assert_equal false, AppSetting.current.reload.quota_pool_available,
      "the next check! fires it once, rather than this firing a second session now"
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
end
