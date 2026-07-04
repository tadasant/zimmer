# frozen_string_literal: true

# Saves a quota check result as a point-in-time snapshot for a Claude account.
#
# This bridges QuotaCheckService::Result (live API probe) and
# ClaudeAccountQuotaSnapshot (database record) so quota data persists
# across page loads and account rotations.
class QuotaSnapshotService
  # Save a QuotaCheckService::Result as a snapshot for the given account.
  #
  # @param account [ClaudeAccount] the account to save the snapshot for
  # @param result [QuotaCheckService::Result] the quota check result
  # @param trigger [String] why the snapshot was taken ("rotation", "page_view", "scheduled")
  # @return [ClaudeAccountQuotaSnapshot] the created snapshot
  def self.save_snapshot(account, result, trigger:)
    account.quota_snapshots.create!(
      subscription_type: result.subscription_type,
      rate_limit_tier: result.rate_limit_tier,
      utilization_5h: result.utilization_5h,
      utilization_7d: result.utilization_7d,
      status_5h: result.status_5h,
      status_7d: result.status_7d,
      reset_5h: result.reset_5h,
      reset_7d: result.reset_7d,
      overage_status: result.overage_status,
      overage_disabled_reason: result.overage_disabled_reason,
      trigger: trigger
    )
  end
end
