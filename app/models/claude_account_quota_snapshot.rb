# frozen_string_literal: true

# Point-in-time quota reading for a Claude account.
#
# Snapshots are taken:
# - On account rotation (captures state of outgoing and incoming accounts)
# - When bootstrap validates a candidate before making it current
# - On quotas page load (live probe of current account)
# - By periodic cron (future extension)
#
# The trigger field records why the snapshot was taken: "rotation", "bootstrap",
# "manual_refresh", "page_view", or "scheduled".
#
# A snapshot outlives the account it was taken for: deleting a ClaudeAccount
# nullifies `claude_account_id` rather than destroying the reading, so the
# account's history survives the delete-and-re-authenticate loop. `account_email`
# and `account_runtime` are captured at write time, because a nulled foreign key
# alone would leave a reading attributable to nobody.
class ClaudeAccountQuotaSnapshot < ApplicationRecord
  belongs_to :claude_account, optional: true

  # Required to create, allowed to become nil later. A snapshot with no account
  # is only ever the residue of a deleted one, never something written that way.
  validates :claude_account, presence: true, on: :create

  before_validation :capture_account_identity, on: :create

  scope :recent, -> { order(created_at: :desc) }

  # Readings still attached to a live account. The rate metric walks consecutive
  # pairs per account, and orphans from different deleted accounts share the same
  # nil key — pairing across them would invent consumption that never happened.
  scope :attached, -> { where.not(claude_account_id: nil) }

  # The account this reading belonged to has since been deleted, leaving the row
  # behind as history.
  def detached?
    claude_account_id.nil?
  end

  # The `anthropic-ratelimit-unified-*-status` values that mean the window is
  # still serving. "allowed_warning" is an account approaching its cap, not one
  # past it. Anything else — "rejected", or a value Anthropic adds later — is
  # read as blocking, so an unknown status errs toward reporting exhaustion.
  SERVING_QUOTA_STATUSES = %w[allowed allowed_warning].freeze

  # A window counts as clear once its counter is back under the cap. The
  # previous 80% threshold was too conservative — it kept an account exceeded at
  # 90% weekly utilization even with the 5-hour window fully reset, which left
  # the whole pool stuck.
  CLEAR_UTILIZATION_THRESHOLD = 1.0

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

  # True when this reading says the account can serve again: both windows are
  # clear, so nothing about it justifies a quota_exceeded label.
  #
  # A window is clear when its reset time has passed or is unknown, OR when its
  # counter has dropped below the cap. Claude's windows slide, so utilization
  # falls before the reset timestamp arrives — reading only the reset time left
  # accounts exceeded long after their usage had drained away.
  #
  # Except on the weekly window, where the status Anthropic reported outranks the
  # counter (#seven_day_window_spent?). An account the API is rejecting for the
  # week cannot serve a request no matter what its utilization reads, and calling
  # it clear puts it straight back in front of rotation (#248).
  #
  # The counterpart to #seven_day_window_spent?, and it lives here for the same
  # reason: QuotaResetCheckerJob restores an account on this, QuotasController
  # heals one on it, and /quotas decides what status badge to render from it.
  # They must agree, or the page and the pool describe different accounts.
  def windows_clear?
    return false if seven_day_window_spent?

    window_dimension_clear?(reset_5h, utilization_5h) &&
      window_dimension_clear?(reset_7d, utilization_7d)
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

  private

  def capture_account_identity
    self.account_email ||= claude_account&.email
    self.account_runtime ||= claude_account&.runtime
  end

  def window_dimension_clear?(reset_time, utilization)
    return true if reset_time.nil? || reset_time <= Time.current
    return true if utilization.present? && utilization < CLEAR_UTILIZATION_THRESHOLD

    false
  end
end
