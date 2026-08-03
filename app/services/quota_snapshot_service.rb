# frozen_string_literal: true

# Saves a quota check result as a point-in-time snapshot for a Claude account.
#
# This bridges QuotaCheckService::Result (live API probe) and
# ClaudeAccountQuotaSnapshot (database record) so quota data persists
# across page loads and account rotations.
#
# It is also where an account's status learns about its own weekly window. The
# other caller of `mark_quota_exceeded!` acts on the account that is CURRENT when
# a session hits a wall, which leaves an account that filled its 7-day window
# while sitting idle in the pool `active`, in `ClaudeAccount.available`, and the
# next thing rotation reaches for — activate, fail on the first request, rotate
# again (#248). A reading that says the week is spent marks the account here, as
# it lands, whichever path took it.
class QuotaSnapshotService
  # Save a QuotaCheckService::Result as a snapshot for the given account, and
  # mark the account quota_exceeded when the reading says its weekly allowance
  # is gone.
  #
  # @param account [ClaudeAccount] the account to save the snapshot for
  # @param result [QuotaCheckService::Result] the quota check result
  # @param trigger [String] why the snapshot was taken ("rotation", "page_view", "scheduled")
  # @return [ClaudeAccountQuotaSnapshot] the created snapshot
  def self.save_snapshot(account, result, trigger:)
    snapshot = create_snapshot(account, result, trigger)
    mark_capped(account, snapshot)
    snapshot
  end

  # Take an account out of the rotation pool when its own quota reading says it
  # cannot serve. Only ever moves an `active` account: `needs_reauth` is a
  # different failure with a different recovery (a human), and relabelling it
  # would make an unusable pool look merely throttled — the same reasoning
  # AccountRotationService#rotate_under_lock applies.
  #
  # QuotaResetCheckerJob restores the account once the window clears, reading the
  # same predicate, so this cannot strand an account whose week has since reset.
  def self.mark_capped(account, snapshot)
    return unless account.active?
    return unless snapshot.seven_day_window_spent?

    account.mark_quota_exceeded!
    Rails.logger.info "[QuotaSnapshotService] Marked #{account.email} quota_exceeded: " \
      "the 7-day window is spent (utilization #{snapshot.utilization_7d.inspect}, status #{snapshot.status_7d.inspect})"
  end
  private_class_method :mark_capped

  def self.create_snapshot(account, result, trigger)
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
      trigger: trigger,
      # Captured here because nothing else can reconstruct it later: session
      # status is mutable and keeps no history, so a reading taken today cannot
      # be attributed to a number of sessions tomorrow. ClaudeUsageRateService
      # divides utilization consumed by the session-hours this number implies.
      active_session_count: ClaudeUsageRateService.active_session_count
    )
  end
  private_class_method :create_snapshot
end
