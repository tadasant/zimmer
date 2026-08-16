# frozen_string_literal: true

# Takes a scheduled quota reading of the account that is currently serving, so
# the spot gate is deciding on a fresh number.
#
# == Why this job has to exist
#
# QuotaResetCheckerJob already runs every 15 minutes and already writes snapshots
# — but only for accounts in `quota_exceeded`, because its job is to notice when
# one recovers. A healthy account only got a reading when somebody opened /quotas
# or a rotation happened, which can be days apart — and the serving account is
# the one utilization is actually accruing against, so its reading is the one
# moving fastest under the pool average the spot gate decides on.
#
# == Cost
#
# One `QuotaCheckService` probe per run: a profile GET plus a 1-token message
# POST, purely to read the rate-limit response headers. At the 15-minute cadence
# in config/environments/*.rb that is 96 probes a day against one account.
#
# Failures are swallowed. A missing sample leaves the gate deciding on a slightly
# older reading; it must never take down the scheduler or mark an account on a
# network blip — only QuotaSnapshotService decides what a reading means for
# account status, and it does so identically no matter which caller supplied the
# reading.
class ClaudeUsageSamplerJob < ApplicationJob
  queue_as :default

  def perform
    account = serving_account
    unless account
      Rails.logger.debug("[ClaudeUsageSamplerJob] No serving Claude Code account — nothing to sample")
      return
    end

    token = access_token_for(account)
    unless token
      Rails.logger.info("[ClaudeUsageSamplerJob] No usable token for #{account.email} — skipping sample")
      return
    end

    result = QuotaCheckService.check_with_token(token)
    unless result.success?
      Rails.logger.info("[ClaudeUsageSamplerJob] Quota probe failed for #{account.email}: #{result.error_message}")
      return
    end

    QuotaSnapshotService.save_snapshot(account, result, trigger: "usage_sample")
  rescue StandardError => e
    Rails.logger.warn("[ClaudeUsageSamplerJob] Sampling failed: #{e.class}: #{e.message}")
    nil
  end

  private

  # The account spend accrues against: the current one, falling back to the
  # highest-priority available account when nothing is flagged current.
  def serving_account
    scope = ClaudeAccount.for_runtime("claude_code")
    scope.find_by(is_current: true, status: :active) || scope.available.first
  end

  def access_token_for(account)
    if (account.token_expired? || account.token_expiring_soon?) && account.can_refresh_token?
      return nil unless account.refresh_token!

      account.reload
    end
    return nil if account.token_expired?

    account.oauth_config&.dig("credentials_json", "claudeAiOauth", "accessToken").presence
  end
end
