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
    return true if window_refused?(status_7d, reset_7d)

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
  # Except that a status Anthropic is still refusing on outranks the counter, on
  # either window. An account the API is turning away cannot serve a request no
  # matter what its utilization reads, and calling it clear puts it straight back
  # in front of rotation (#248). The 5-hour window used to be counter-only, on the
  # grounds that it slides and clears within the hour — but a card cannot render
  # "Rejected" against that window and "Active" for the account in the same
  # breath, which is the contradiction this predicate now decides.
  #
  # The counterpart to #seven_day_window_spent?, and it lives here for the same
  # reason: QuotaResetCheckerJob restores an account on this, QuotasController
  # heals one on it, and /quotas decides what status badge to render from it.
  # They must agree, or the page and the pool describe different accounts.
  def windows_clear?
    return false if seven_day_window_spent?
    return false if window_refused?(status_5h, reset_5h)

    window_dimension_clear?(reset_5h, utilization_5h) &&
      window_dimension_clear?(reset_7d, utilization_7d)
  end

  # The 5-hour utilization this account contributes to a pool figure.
  #
  # An account whose weekly allowance is spent cannot serve a request no matter
  # how much 5-hour headroom its counter reports, so it counts as fully utilized.
  # Anywhere else this is the raw 5-hour figure, which keeps the number to one
  # statement: 5-hour utilization, with weekly-blocked accounts counted as 100%.
  #
  # The correction runs one way. The 7-day window subsumes the 5-hour one: an
  # account at its 5-hour cap is idle for minutes and then serves again, so it
  # must never be reported as having burned its week.
  #
  # Lives here rather than in the view helper because the spot gate decides on
  # the same figure /quotas renders — see ClaudeAccountPool.
  def pool_utilization_5h
    return 1.0 if seven_day_window_spent?

    self.class.effective_utilization(utilization_5h, reset_5h)
  end

  # The 7-day utilization this account contributes to a pool figure. Needs no
  # correction: a spent weekly window already reads as 100% here.
  def pool_utilization_7d
    self.class.effective_utilization(utilization_7d, reset_7d)
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

  # True when the status Anthropic reported for a window is a refusal that has
  # not yet expired. A status, like a counter, describes the window that was open
  # when the reading was taken — once that window's reset passes the sliding
  # window has cleared and the refusal says nothing about the account today.
  def window_refused?(status, reset_time)
    return false if status.blank? || SERVING_QUOTA_STATUSES.include?(status)

    reset_time.nil? || reset_time > Time.current
  end

  def window_dimension_clear?(reset_time, utilization)
    return true if reset_time.nil? || reset_time <= Time.current
    return true if utilization.present? && utilization < CLEAR_UTILIZATION_THRESHOLD

    false
  end
end
