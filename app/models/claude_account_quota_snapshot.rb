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

  # The `anthropic-ratelimit-unified-*-status` values that mean the window is
  # still serving. "allowed_warning" is an account approaching its cap, not one
  # past it. Anything else — "rejected", or a value Anthropic adds later — is
  # read as blocking, so an unknown status errs toward reporting exhaustion.
  SERVING_QUOTA_STATUSES = %w[allowed allowed_warning].freeze

  # The utilization a window actually carries right now. Once a window's reset
  # time has passed the sliding window has cleared, so the recorded number says
  # nothing about what the account can serve today.
  def self.effective_utilization(utilization, reset_time)
    return utilization if utilization.nil? || reset_time.nil?
    return 0.0 if reset_time <= Time.current

    utilization
  end

  # True when the weekly allowance this snapshot recorded is gone: the API was
  # rejecting on the 7-day window, or its counter had reached the cap. Either way
  # the account cannot serve a request until that window resets.
  #
  # A status, like a number, holds only until its reset time passes — after that
  # the sliding window has cleared, the same rule .effective_utilization applies.
  #
  # This is the one definition of "the week is spent". /quotas reads it to decide
  # what an account contributes to the pool figure, QuotaSnapshotService reads it
  # to mark an account quota_exceeded as the reading lands, AccountRotationService
  # reads it to refuse a capped candidate, and QuotaResetCheckerJob reads it to
  # decide the account is not back yet. They must agree, or an account flips
  # between exceeded and active on every sweep.
  def seven_day_window_spent?
    blocked = status_7d.present? && SERVING_QUOTA_STATUSES.exclude?(status_7d)
    return false if blocked && reset_7d && reset_7d <= Time.current
    return true if blocked

    eff_7d = self.class.effective_utilization(utilization_7d, reset_7d)
    !eff_7d.nil? && eff_7d >= 1.0
  end

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
