# frozen_string_literal: true

# Proactively refreshes X (Twitter) OAuth access tokens before they expire.
#
# Runs on a GoodJob cron schedule. X access tokens live ~2h and X rotates refresh
# tokens single-use, so this job keeps a freshly-minted access token on the
# XOauthCredential row (which session-prep injects via XOauthTokenVendor) AND
# keeps the rotating refresh-token chain alive ahead of X's ~6-month refresh-token
# expiry. A session that actually launches also refreshes on demand
# (XOauthCredential#current_access_token), so this cron is belt-and-suspenders.
#
# Failure handling mirrors RefreshMcpOauthTokensJob (the Zimmer precedent):
#   - Network errors where the request never reached the endpoint (connection
#     never established) are safe to retry — the single-use refresh token was
#     NOT consumed. Retried with exponential backoff.
#   - Network errors after the request may have been transmitted (response lost
#     in flight) are NOT retried in-band: with a rotating-refresh-token provider,
#     re-sending the old token can trip reuse-detection and permanently kill the
#     chain. Deferred to the next scheduled run.
#   - HTTP 429 / 5xx (endpoint reachable, transient upstream) are retried.
#   - Only after retries are exhausted is a failure logged at .error, so a
#     genuinely persistent outage stays alertable while self-resolving blips stay
#     at .info (see the root CLAUDE.md Logging Philosophy).
class RefreshXOauthTokensJob < ApplicationJob
  include DatabaseRetry
  queue_as :default

  # Refresh access tokens expiring within this window.
  REFRESH_WINDOW = 30.minutes

  # See RefreshMcpOauthTokensJob: connection never established → token intact → retry.
  RETRYABLE_REFRESH_ERRORS = [
    Net::OpenTimeout,
    Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH,
    SocketError
  ].freeze

  # Response may have been lost in flight → don't re-send the single-use token.
  AMBIGUOUS_REFRESH_ERRORS = [
    Net::ReadTimeout,
    Errno::ECONNRESET,
    Errno::ETIMEDOUT,
    Errno::EPIPE,
    IOError,
    OpenSSL::SSL::SSLError,
    Timeout::Error
  ].freeze

  MAX_RETRIES = 3
  RETRY_BACKOFF = 2.minutes

  # @param retry_credential_ids [Array<Integer>, nil] ids to retry after a transient failure
  # @param attempt [Integer, nil] current retry attempt (1-based)
  def perform(retry_credential_ids: nil, attempt: nil)
    if retry_credential_ids.present?
      perform_retry(retry_credential_ids, attempt)
    else
      perform_scheduled_refresh
    end
  end

  private

  def perform_scheduled_refresh
    refreshed = 0
    failed = 0
    retry_ids = []

    credentials_needing_refresh.find_each do |credential|
      case refresh_within_lock(credential)
      when :refreshed
        refreshed += 1
      when :retry
        failed += 1
        retry_ids << credential.id
      when :failed
        failed += 1
      end
    rescue *RETRYABLE_REFRESH_ERRORS => e
      failed += 1
      retry_ids << credential.id
      Rails.logger.info "[RefreshXOauthTokensJob] Transient error refreshing #{credential.account_key}: #{e.class}: #{e.message} (will retry)"
    rescue *AMBIGUOUS_REFRESH_ERRORS => e
      failed += 1
      Rails.logger.info "[RefreshXOauthTokensJob] Ambiguous network failure refreshing #{credential.account_key}: #{e.class}: #{e.message} — not retrying to avoid refresh-token reuse-detection; will re-attempt on the next scheduled run"
    rescue StandardError => e
      failed += 1
      Rails.logger.error "[RefreshXOauthTokensJob] Error refreshing #{credential.account_key}: #{e.message}"
    end

    schedule_retry(retry_ids, 1) if retry_ids.any?

    if refreshed > 0 || failed > 0
      Rails.logger.info "[RefreshXOauthTokensJob] Refreshed #{refreshed} token(s), #{failed} failure(s)"
    end
  end

  def perform_retry(credential_ids, attempt)
    refreshed = 0
    still_failing_ids = []

    XOauthCredential.where(id: credential_ids).find_each do |credential|
      outcome = refresh_within_lock(credential)
      still_failing_ids << credential.id if outcome == :retry
      refreshed += 1 if outcome == :refreshed
    rescue *RETRYABLE_REFRESH_ERRORS => e
      still_failing_ids << credential.id
      if attempt < MAX_RETRIES
        Rails.logger.info "[RefreshXOauthTokensJob] Transient error refreshing #{credential.account_key} on retry #{attempt}: #{e.class}: #{e.message} (will retry)"
      else
        Rails.logger.error "[RefreshXOauthTokensJob] Token refresh for #{credential.account_key} failed after #{MAX_RETRIES} retries: #{e.class}: #{e.message}"
      end
    rescue *AMBIGUOUS_REFRESH_ERRORS => e
      Rails.logger.info "[RefreshXOauthTokensJob] Ambiguous network failure refreshing #{credential.account_key} on retry #{attempt}: #{e.class}: #{e.message} — not retrying; deferring to the next scheduled run"
    rescue StandardError => e
      Rails.logger.error "[RefreshXOauthTokensJob] Error refreshing #{credential.account_key} on retry #{attempt}: #{e.message}"
    end

    schedule_retry(still_failing_ids, attempt + 1) if still_failing_ids.any? && attempt < MAX_RETRIES

    Rails.logger.info "[RefreshXOauthTokensJob] Retry #{attempt}/#{MAX_RETRIES}: #{refreshed} refreshed, #{still_failing_ids.size} still failing"
  end

  # Refreshes one credential under a row lock (so concurrent workers / on-demand
  # session-prep refreshes don't both rotate the single-use token). Returns a
  # symbol describing the outcome; network errors propagate to the caller's
  # rescue clauses for retryable/ambiguous classification.
  #
  # @return [Symbol] :refreshed, :retry (429/5xx — transient upstream), :failed, or :skipped
  def refresh_within_lock(credential)
    credential.with_lock do
      # Re-check inside the lock — another worker may have refreshed already.
      next :skipped unless credential.expiring_soon?(REFRESH_WINDOW)
      next :skipped unless credential.can_refresh?

      case credential.refresh!
      when true then :refreshed
      when :rate_limited, :server_error then :retry
      else :failed
      end
    end
  end

  def schedule_retry(credential_ids, attempt)
    wait = RETRY_BACKOFF * (2**(attempt - 1))
    Rails.logger.info "[RefreshXOauthTokensJob] #{credential_ids.size} credential(s) failed transiently, scheduling retry #{attempt}/#{MAX_RETRIES} in #{wait.to_i}s"
    self.class.set(wait: wait).perform_later(retry_credential_ids: credential_ids, attempt: attempt)
  end

  def credentials_needing_refresh
    XOauthCredential.refreshable.where(
      "expires_at IS NULL OR expires_at < ?", REFRESH_WINDOW.from_now
    )
  end
end
