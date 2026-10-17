# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class AccountRebalanceServiceTest < ActiveSupport::TestCase
  BUSY = RunningTurns::Reading.new(on_a_worker: 1, awaiting_a_worker: 0, asleep: 0)
  QUEUED = RunningTurns::Reading.new(on_a_worker: 0, awaiting_a_worker: 1, asleep: 0)

  setup do
    @primary = claude_accounts(:primary)     # current
    @secondary = claude_accounts(:secondary)
    @tertiary = claude_accounts(:tertiary)
    ClaudeAccountQuotaSnapshot.where(claude_account: ClaudeAccount.for_runtime("claude_code")).delete_all

    # The live state that motivated this: the current account at 81% of its week
    # with a day and a half to go, one untouched account, one at 36%.
    read(@primary, u5: 0.05, u7: 0.81, reset_7d: 36.hours.from_now)
    read(@secondary, u7: 0.0)
    read(@tertiary, u7: 0.36, reset_7d: 4.days.from_now)

    Session.stubs(:running_turns).returns(RunningTurns::EMPTY)
    quiet_since(2.hours.ago)
    probe_returns(u5: 0.0, u7: 0.0)

    @service = AccountRebalanceService.new(enabled: true, idle_window: 60.minutes, min_gain: 0.15)
  end

  def read(account, u5: 0.0, u7: 0.0, reset_7d: 6.days.from_now, at: 5.minutes.ago)
    account.quota_snapshots.create!(
      utilization_5h: u5, utilization_7d: u7, status_5h: "allowed", status_7d: "allowed",
      reset_5h: nil, reset_7d: reset_7d, trigger: "usage_sample", created_at: at
    )
  end

  def quiet_since(time)
    Session.where(agent_runtime: "claude_code").update_all(last_timeline_entry_at: time)
  end

  def probe_returns(u5:, u7:, status_7d: "allowed")
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(
        success: true, subscription_type: "claude_max", rate_limit_tier: "tier_4",
        utilization_5h: u5, utilization_7d: u7, status_5h: "allowed", status_7d: status_7d,
        reset_5h: nil, reset_7d: 6.days.from_now
      )
    )
  end

  def assert_stayed_on(account)
    assert_no_difference -> { AccountRotationEvent.count } do
      yield
    end
    assert account.reload.is_current?, "the pool should not have moved off #{account.email}"
  end

  test "an idle pool moves to the best-scoring account and logs a rebalance" do
    result = nil
    assert_difference -> { AccountRotationEvent.count }, 1 do
      result = @service.rebalance!
    end

    assert result[:rebalanced]
    assert @secondary.reload.is_current?
    assert_not @primary.reload.is_current?

    event = AccountRotationEvent.order(:created_at).last
    assert_equal "rebalance", event.reason
    assert_equal "automatic", event.source
    assert_equal @primary, event.rotated_from
    assert_equal @secondary, event.rotated_to
    assert_match(/0\.34 → 1\.00/, event.triggered_by)
  end

  test "a rebalance does not condemn the account it leaves" do
    @service.rebalance!

    assert @primary.reload.active?
    assert_equal 0, @primary.quota_hit_count
  end

  test "a rebalance re-reads the candidate before switching" do
    assert_difference -> { @secondary.quota_snapshots.where(trigger: "rebalance").count }, 1 do
      @service.rebalance!
    end
  end

  test "no rotation while a turn is on a worker" do
    Session.stubs(:running_turns).returns(BUSY)

    assert_stayed_on(@primary) { assert_equal :busy, @service.rebalance![:state] }
  end

  test "no rotation while a turn is queued for a worker" do
    Session.stubs(:running_turns).returns(QUEUED)

    assert_stayed_on(@primary) { assert_equal :busy, @service.rebalance![:state] }
  end

  test "no rotation before the pool has been idle for an hour" do
    quiet_since(59.minutes.ago)

    assert_stayed_on(@primary) { assert_equal :inside_idle_window, @service.rebalance![:state] }

    plan = @service.plan
    assert_equal :inside_idle_window, plan.state
    assert_in_delta 1.minute.from_now, plan.idle_until, 2.seconds
  end

  test "rotates once the hour is up" do
    quiet_since(61.minutes.ago)

    assert @service.rebalance![:rebalanced]
    assert @secondary.reload.is_current?
  end

  test "a turn that starts while the candidate is being probed calls the switch off" do
    Session.stubs(:running_turns).returns(RunningTurns::EMPTY).then.returns(BUSY)

    assert_stayed_on(@primary) { assert_equal :busy, @service.rebalance![:state] }
  end

  # Hysteresis. A current account a few points behind the best is not worth a
  # switch, and once switched, the pool does not swap straight back.
  test "does not flap between near-equal accounts" do
    @primary.quota_snapshots.delete_all
    read(@primary, u7: 0.10)

    assert_stayed_on(@primary) { assert_equal :current_is_best, @service.rebalance![:state] }
  end

  test "a second sweep after a rebalance stays put" do
    assert @service.rebalance![:rebalanced]

    assert_stayed_on(@secondary) { assert_not @service.rebalance![:rebalanced] }
  end

  test "stays put when the candidate's fresh reading no longer clears the bar" do
    probe_returns(u5: 0.0, u7: 0.85)

    assert_stayed_on(@primary) { assert_equal :current_is_best, @service.rebalance![:state] }
  end

  test "skips candidates with a stale reading" do
    @secondary.quota_snapshots.delete_all
    read(@secondary, at: 3.hours.ago)

    @service.rebalance!

    assert @tertiary.reload.is_current?, "the 36% account is the best one with a fresh reading"
  end

  test "skips candidates that are not active" do
    @secondary.update_columns(status: ClaudeAccount.statuses[:needs_reauth])

    @service.rebalance!

    assert @tertiary.reload.is_current?
  end

  test "holds when the current account has no fresh reading" do
    @primary.quota_snapshots.delete_all

    assert_stayed_on(@primary) { assert_equal :no_current_reading, @service.rebalance![:state] }
  end

  test "does nothing when disabled" do
    service = AccountRebalanceService.new(enabled: false, idle_window: 60.minutes, min_gain: 0.15)

    assert_stayed_on(@primary) { assert_equal :disabled, service.rebalance![:state] }
  end

  test "the plan ranks every scored account, best first" do
    plan = @service.plan

    assert_equal :due, plan.state
    assert_equal @secondary, plan.best
    assert_equal [ @secondary, @tertiary, @primary ], plan.ranking.map(&:account)
  end

  test "does not switch onto an account nearly out of its week, however soon it resets" do
    @secondary.quota_snapshots.delete_all
    read(@secondary, u7: 0.98, reset_7d: 12.hours.from_now)
    @tertiary.update_columns(status: ClaudeAccount.statuses[:needs_reauth])

    assert_stayed_on(@primary) { assert_equal :no_candidate, @service.rebalance![:state] }
  end

  test "does not switch onto an account nearly out of its 5-hour window" do
    @secondary.quota_snapshots.delete_all
    read(@secondary, u5: 0.95, u7: 0.0)
    @tertiary.update_columns(status: ClaudeAccount.statuses[:needs_reauth])

    assert_stayed_on(@primary) { assert_equal :no_candidate, @service.rebalance![:state] }
  end

  test "a human's Switch holds the pool for a day" do
    AccountRotationEvent.create!(rotated_from: @secondary, rotated_to: @primary, source: "manual",
      reason: "manual", created_at: 3.hours.ago)

    assert_stayed_on(@primary) { assert_equal :manual_hold, @service.rebalance![:state] }

    travel 22.hours do
      quiet_since(2.hours.ago)
      read(@primary, u5: 0.05, u7: 0.81, reset_7d: 14.hours.from_now)
      read(@secondary)
      assert @service.rebalance![:rebalanced]
    end
  end

  test "a current account that cannot serve is left even without a fresh reading or past a manual switch" do
    @primary.quota_snapshots.delete_all
    @primary.update_columns(status: ClaudeAccount.statuses[:needs_reauth])
    AccountRotationEvent.create!(rotated_from: @secondary, rotated_to: @primary, source: "manual", created_at: 1.hour.ago)

    assert @service.rebalance![:rebalanced]
    assert @secondary.reload.is_current?
  end

  test "a fleet that cannot be read holds" do
    Session.stubs(:running_turns).raises(ActiveRecord::StatementInvalid, "boom")

    assert_stayed_on(@primary) { assert_equal :fleet_unreadable, @service.rebalance![:state] }
  end

  test "a pool with no Claude Code activity ever counts as idle" do
    Session.update_all(last_timeline_entry_at: nil)

    assert @service.rebalance![:rebalanced]
  end

  test "stays put when the candidate cannot be probed" do
    QuotaCheckService.stubs(:check_with_token).returns(
      QuotaCheckService::Result.new(success: false, unreachable: true, error_message: "connection refused")
    )

    assert_stayed_on(@primary) { assert_equal :candidate_unprobeable, @service.rebalance![:state] }
  end

  test "stays put when another rotation holds the pool lock" do
    ClaudeAccount.stubs(:with_pool_lock).returns(nil)

    assert_stayed_on(@primary) { assert_equal :rotation_in_flight, @service.rebalance![:state] }
  end

  test "a rebalance re-ranks priorities by score" do
    @service.rebalance!

    assert_equal 0, @secondary.reload.priority
    assert_operator @tertiary.reload.priority, :<, @primary.reload.priority,
      "the 36% account outranks the 81% one"
  end

  test "the job swallows an error rather than failing the cron" do
    AccountRebalanceService.any_instance.stubs(:rebalance!).raises(StandardError, "boom")

    assert_nil AccountRebalanceJob.perform_now
  end

  test "the job runs the rebalance" do
    AccountRebalanceJob.perform_now

    assert @secondary.reload.is_current?
  end
end
