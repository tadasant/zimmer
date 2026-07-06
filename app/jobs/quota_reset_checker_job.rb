# frozen_string_literal: true

# Periodic job that checks if quota-exceeded accounts can be restored to active.
#
# Uses both reset times and utilization from each account's latest quota snapshot
# to determine if the quota window has cleared. Runs every 15 minutes in production.
#
# A window is considered clear if:
# - The reset time is nil or in the past, OR
# - The utilization is below RESTORE_UTILIZATION_THRESHOLD (sliding window dropped)
#
# Claude's API uses sliding windows, so utilization can drop below 100%
# before the reset timestamp arrives. Relying solely on reset times causes
# accounts to stay stuck in quota_exceeded status long after usage has dropped.
class QuotaResetCheckerJob < ApplicationJob
  # Restore accounts when utilization drops below 100%.
  # The previous 80% threshold was too conservative — it blocked restoration
  # for accounts with 90% 7-day utilization even when the 5-hour window had
  # fully reset, causing all accounts to stay stuck in quota_exceeded.
  RESTORE_UTILIZATION_THRESHOLD = 1.0

  def perform
    logger = StructuredLogger.new({ service: "QuotaResetCheckerJob" })

    # Scoped to Claude Code: this job probes Anthropic's quota API via snapshots,
    # which doesn't apply to other runtimes (Codex has no Anthropic quota window).
    ClaudeAccount.quota_exceeded.for_runtime(ClaudeAuthProvider::RUNTIME).find_each do |account|
      snapshot = fetch_fresh_snapshot(account, logger) || account.latest_snapshot
      next unless snapshot

      if window_clear?(snapshot)
        account.update!(status: :active)
        logger.info("Restored account to active",
          email: account.email,
          utilization_5h: snapshot.utilization_5h,
          utilization_7d: snapshot.utilization_7d,
          reset_5h: snapshot.reset_5h&.iso8601,
          reset_7d: snapshot.reset_7d&.iso8601)
      end
    end
  end

  # Check if both quota windows are clear based on reset times and utilization.
  # A window is clear if its reset time has passed OR its utilization has dropped
  # below the restore threshold.
  def self.window_clear?(snapshot)
    five_hour_clear = window_dimension_clear?(snapshot.reset_5h, snapshot.utilization_5h)
    seven_day_clear = window_dimension_clear?(snapshot.reset_7d, snapshot.utilization_7d)

    five_hour_clear && seven_day_clear
  end

  def self.window_dimension_clear?(reset_time, utilization)
    return true if reset_time.nil? || reset_time <= Time.current
    return true if utilization.present? && utilization < RESTORE_UTILIZATION_THRESHOLD

    false
  end

  private

  def window_clear?(snapshot)
    self.class.window_clear?(snapshot)
  end

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

    token = account.oauth_config&.dig("credentials_json", "claudeAiOauth", "accessToken")
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
        token = account.oauth_config&.dig("credentials_json", "claudeAiOauth", "accessToken")
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
