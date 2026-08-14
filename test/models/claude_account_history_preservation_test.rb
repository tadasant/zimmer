# frozen_string_literal: true

require "test_helper"

# Deleting an account must not delete the evidence of how it behaved.
#
# The operator gesture these tests protect is "delete it and re-authenticate" —
# the two adjacent buttons on every /quotas card. It used to cascade an account's
# quota snapshots, login attempts, and inbound rotation events out of existence,
# leaving a freshly re-added row that read as "this account has never completed a
# single successful call". See https://github.com/tadasant/zimmer/issues/241.
class ClaudeAccountHistoryPreservationTest < ActiveSupport::TestCase
  setup do
    @account = claude_accounts(:secondary)
    @email = @account.email
  end

  test "deleting an account preserves its quota snapshots" do
    snapshot = QuotaSnapshotService.save_snapshot(@account, quota_result, trigger: "page_view")

    assert_no_difference "ClaudeAccountQuotaSnapshot.count" do
      @account.destroy!
    end

    snapshot.reload
    assert_nil snapshot.claude_account_id, "the snapshot should outlive the account, detached"
    assert snapshot.detached?
    assert_equal @email, snapshot.account_email, "a reading attributable to nobody preserves nothing"
    assert_equal "claude_code", snapshot.account_runtime
  end

  test "deleting an account preserves its login attempts" do
    attempt = @account.runtime_login_attempts.create!(runtime: @account.runtime, status: "failed")

    assert_no_difference "RuntimeLoginAttempt.count" do
      @account.destroy!
    end

    attempt.reload
    assert_nil attempt.claude_account_id
    assert attempt.detached?
    assert_equal @email, attempt.account_email
    assert_equal "failed", attempt.status, "the outcome is the whole point of keeping the row"
  end

  test "deleting an account preserves rotation events that targeted it" do
    event = AccountRotationEvent.create!(
      rotated_from: claude_accounts(:primary),
      rotated_to: @account,
      reason: "quota_exceeded",
      source: "automatic"
    )

    assert_no_difference "AccountRotationEvent.count" do
      @account.destroy!
    end

    event.reload
    assert_nil event.rotated_to_id
    assert event.to_deleted?
    assert_equal @email, event.to_email
    assert_equal "claude_code", event.runtime, "the event must stay filterable to its runtime tab"
  end

  test "deleting an account preserves rotation events that originated from it" do
    event = AccountRotationEvent.create!(
      rotated_from: @account,
      rotated_to: claude_accounts(:primary),
      reason: "quota_exceeded",
      source: "automatic"
    )

    @account.destroy!
    event.reload

    assert_nil event.rotated_from_id
    assert event.from_deleted?, "a deleted source must not read as no source at all"
    assert_equal @email, event.from_email
  end

  test "a rotation with no source stays distinguishable from one whose source was deleted" do
    bootstrap = AccountRotationEvent.create!(
      rotated_from: nil,
      rotated_to: claude_accounts(:primary),
      reason: "bootstrap",
      source: "manual"
    )
    from_deleted = AccountRotationEvent.create!(
      rotated_from: @account,
      rotated_to: claude_accounts(:primary),
      reason: "quota_exceeded",
      source: "automatic"
    )

    @account.destroy!

    assert_not bootstrap.reload.from_deleted?
    assert_nil bootstrap.from_email
    assert from_deleted.reload.from_deleted?
    assert_equal @email, from_deleted.from_email
  end

  test "deleting an account leaves the pool otherwise untouched" do
    # The delete still has to work — preserving history must not turn Delete into
    # a control that errors on any account old enough to have any.
    QuotaSnapshotService.save_snapshot(@account, quota_result, trigger: "page_view")
    @account.runtime_login_attempts.create!(runtime: @account.runtime, status: "succeeded")
    AccountRotationEvent.create!(rotated_to: @account, reason: "quota_exceeded", source: "automatic")

    assert_difference "ClaudeAccount.count", -1 do
      assert @account.destroy
    end
  end

  private

  def quota_result
    QuotaCheckService::Result.new(
      success: true,
      subscription_type: "claude_max",
      rate_limit_tier: "tier_4",
      utilization_5h: 0.5,
      utilization_7d: 0.3,
      status_5h: "allowed",
      status_7d: "allowed",
      reset_5h: 3.hours.from_now,
      reset_7d: 5.days.from_now
    )
  end
end
