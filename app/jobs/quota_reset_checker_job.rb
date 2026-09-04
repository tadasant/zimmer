# frozen_string_literal: true

# Periodic job that checks if quota-exceeded accounts can be restored to active.
#
# Probes each exceeded account for a fresh reading and restores the ones whose
# windows have cleared, per ClaudeAccountQuotaSnapshot#windows_clear?. Runs every
# 15 minutes in production.
#
# Restoring accounts is only half the job: sessions parked by
# AuthOutageParkService because the pool had nothing usable are dormant in
# `waiting`, waiting for someone to notice the pool came back. Two things do,
# and they cover different populations:
#
#   1. QuotaAvailabilityMonitor fires the `quota_available` trigger event on the
#      rising edge, which spawns ONE fleet-maintenance session that decides — in
#      precedence order, against the spot thresholds and the concurrency ceiling —
#      which waiting sessions start. That is how every SPOT session wakes.
#   2. AuthOutageParkService.wake_parked_sessions! resumes parked PRIORITY
#      sessions directly. Priority work is never gated on quota, so making it wait
#      for a fleet session to be spawned and take its first turn would be a
#      regression; it recovers with the accounts, as it always has.
#
# Restoring an account is also what changes the pool fingerprint an
# auth-unrecoverable park waits on, so the sweep covers both park reasons; see
# AuthOutageParkService.wake_parked_sessions! for the evidence each one requires.
#
# This job is the pool's healer, not the page's. A `quota_exceeded` account
# whose windows have cleared must not PRESENT as exceeded on /inference even when
# this job has not run — the deploy that froze every queue for ten hours (#426)
# is what that looks like — so the badge derives its own answer from the same
# ClaudeAccountQuotaSnapshot#windows_clear? this job restores on. See
# ClaudeAccount#effective_status.
class QuotaResetCheckerJob < ApplicationJob
  include SingletonSweep

  def perform
    logger = StructuredLogger.new({ service: "QuotaResetCheckerJob" })

    # Scoped to Claude Code: this job probes Anthropic's quota API via snapshots,
    # which doesn't apply to other runtimes (Codex has no Anthropic quota window).
    ClaudeAccount.quota_exceeded.for_runtime(ClaudeAuthProvider::RUNTIME).find_each do |account|
      snapshot = fetch_fresh_snapshot(account, logger) || account.latest_snapshot
      next unless snapshot

      if snapshot.windows_clear?
        account.update!(status: :active)
        logger.info("Restored account to active",
          email: account.email,
          utilization_5h: snapshot.utilization_5h,
          utilization_7d: snapshot.utilization_7d,
          reset_5h: snapshot.reset_5h&.iso8601,
          reset_7d: snapshot.reset_7d&.iso8601)
      end
    end

    # Order matters: restore the accounts first, then look at the pool. The edge
    # this fires on is the one the loop above just created.
    QuotaAvailabilityMonitor.check!(logger: logger)

    resumed = AuthOutageParkService.wake_parked_sessions!(logger: logger)
    logger.info("Resumed sessions parked for auth outage", count: resumed) if resumed.positive?
  end

  private

  # Fetch a fresh quota snapshot for a non-current account using its stored
  # OAuth token. Returns nil if the token is unavailable, expired without a
  # refresh path, or the API call fails — the caller falls back to the stale
  # snapshot in that case.
  def fetch_fresh_snapshot(account, logger)
    # Refresh tokens if expired or expiring soon
    if (account.token_expired? || account.token_expiring_soon?) && account.can_refresh_token?
      unless account.refresh_token!
        logger.warn("Token refresh failed, using stale snapshot", email: account.email)
        return nil
      end
    end

    token = account.claude_access_token
    unless token.present?
      logger.info("No OAuth token available, using stale snapshot", email: account.email)
      return nil
    end

    # Don't attempt API call with an expired token
    if account.token_expired?
      logger.info("Token expired without refresh path, using stale snapshot", email: account.email)
      return nil
    end

    result = QuotaCheckService.check_with_token(token)

    # On 401, the access token may have been invalidated server-side.
    # Try refreshing and retry once.
    if !result.success? && result.error_message&.include?("401") && account.can_refresh_token?
      if account.refresh_token!
        account.reload
        token = account.claude_access_token
        result = QuotaCheckService.check_with_token(token) if token.present?
      end
    end

    unless result.success?
      logger.warn("Quota check failed, using stale snapshot",
        email: account.email, error: result.error_message)
      return nil
    end

    QuotaSnapshotService.save_snapshot(account, result, trigger: "scheduled")
  rescue StandardError => e
    logger.error("Error fetching fresh snapshot", email: account.email, error: e.message)
    nil
  end
end
