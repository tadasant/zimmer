# frozen_string_literal: true

# Point-in-time quota reading for a Claude account.
#
# Snapshots are taken:
# - On account rotation (captures state of outgoing and incoming accounts)
# - On quotas page load (live probe of current account)
# - By periodic cron (future extension)
#
# The trigger field records why the snapshot was taken: "rotation",
# "manual_refresh", "page_view", or "scheduled".
class ClaudeAccountQuotaSnapshot < ApplicationRecord
  belongs_to :claude_account

  validates :claude_account, presence: true

  scope :recent, -> { order(created_at: :desc) }

  # Returns a hash suitable for display, mirroring QuotaCheckService::Result fields
  def to_display_hash
    {
      subscription_type: subscription_type,
      rate_limit_tier: rate_limit_tier,
      utilization_5h: utilization_5h,
      utilization_7d: utilization_7d,
      status_5h: status_5h,
      status_7d: status_7d,
      reset_5h: reset_5h,
      reset_7d: reset_7d,
      overage_status: overage_status,
      overage_disabled_reason: overage_disabled_reason,
      snapshot_at: created_at,
      trigger: trigger
    }
  end
end
