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
