# Proactively refreshes MCP OAuth tokens before they expire.
#
# Runs every 30 minutes via GoodJob cron. Finds all credentials expiring
# within the next hour and refreshes them using their refresh_token.
# This keeps the token chain alive so that sessions resuming after idle
# periods don't hit expired tokens and trigger slow 60s retry loops in
# Claude Code's MCP client.
#
# Without this job, tokens that expire while no session is running can't
# be refreshed — the refresh token itself may expire or be revoked by the
# OAuth provider after a period of inactivity (commonly 24-48 hours).
#
# Transient failure handling: a refresh can raise a transient network error
# (the token endpoint connection times out, resets, etc.). Rather than logging
# that at .error — which trips the "any Zimmer ERROR log → critical" alert for a
# self-resolving condition — the job either retries (for errors where the request
# never reached the endpoint) or defers to the next scheduled run (for errors
# where the request may already have been processed), logging at .info during
# intermediate attempts. Only after all retries are exhausted is the failure
# logged at .error, so a genuinely persistent outage stays alertable.
class RefreshMcpOauthTokensJob < ApplicationJob
  include DatabaseRetry
  queue_as :default

  # Refresh tokens expiring within this window
  REFRESH_WINDOW = 1.hour

  # Don't attempt to refresh tokens that expired more than this long ago —
  # the refresh token itself is likely expired/revoked by the provider
  MAX_EXPIRED_AGE = 24.hours

  # Minimum gap between two proactive rotations of the same credential.
  #
  # Rotating-refresh-token providers (e.g. Notion) mint a brand-new refresh token
  # on every refresh and revoke the prior one. Each rotation is therefore a chance
  # for a lost/timed-out response to trip the provider's reuse-detection and
  # permanently kill the chain. Access tokens have a short (~1h) TTL, so without a
  # throttle this 30-min cron would rotate on nearly every run (~48×/day), turning
  # a rare lost response into a near-weekly re-auth.
  #
  # We don't need access tokens to stay continuously fresh between sessions — a
  # session that actually runs gets a fresh token on demand via
  # McpOauthCredentialInjector. Proactive refresh only needs to keep the *refresh
  # token* alive ahead of the provider's inactivity-revocation window (commonly
  # 24-48h). Rotating at most once per interval stays comfortably inside that
  # window while cutting rotation-race exposure by ~an order of magnitude.
  PROACTIVE_REFRESH_MIN_INTERVAL = 4.hours

  # Network errors where the request never reached the token endpoint (the
  # connection was never established), so the refresh token was definitely NOT
  # consumed. Safe to retry: the provider issued nothing and our token is intact.
  RETRYABLE_REFRESH_ERRORS = [
    Net::OpenTimeout,
    Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH,
    SocketError
  ].freeze

  # Network errors that strike after the request may already have been
  # transmitted — the response was lost in flight. With a rotating-refresh-token
  # provider the server may have already minted (and revoked our old) refresh
  # token; blindly re-sending the old token trips reuse-detection and permanently
  # revokes the whole chain. So these are NOT retried in-band: we leave the
  # credential untouched and let the next scheduled run attempt a clean refresh
  # (its updated_at is unchanged, so the throttle keeps it eligible immediately).
  # Listed after the retryable set and matched first, so the specific connection-
  # establishment timeouts above win over the generic Timeout::Error catch-all.
  AMBIGUOUS_REFRESH_ERRORS = [
    Net::ReadTimeout,
    Errno::ECONNRESET,
    Errno::ETIMEDOUT,
    Errno::EPIPE,
    IOError,
    OpenSSL::SSL::SSLError,
    Timeout::Error
  ].freeze

  # Retry configuration for transient failures (exponential backoff: 2, 4, 8 min)
  MAX_RETRIES = 3
  RETRY_BACKOFF = 2.minutes

  # @param retry_credential_ids [Array<Integer>, nil] credential IDs to retry after a transient failure
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
      # Use database-level locking to prevent concurrent refresh attempts
      # from multiple workers racing on the same credential
      credential.with_lock do
        # Re-check inside lock — another worker may have already refreshed
        next unless credential.expiring_soon?(REFRESH_WINDOW)
        next unless credential.can_refresh?

        if credential.refresh!
          refreshed += 1
        else
          failed += 1
          Rails.logger.warn "[RefreshMcpOauthTokensJob] Failed to refresh token for #{credential.server_name} (#{credential.credential_key})"
        end
      end
    rescue *RETRYABLE_REFRESH_ERRORS => e
      failed += 1
      retry_ids << credential.id
      Rails.logger.info "[RefreshMcpOauthTokensJob] Transient error refreshing #{credential.server_name}: #{e.class}: #{e.message} (will retry)"
    rescue *AMBIGUOUS_REFRESH_ERRORS => e
      failed += 1
      Rails.logger.info "[RefreshMcpOauthTokensJob] Ambiguous network failure refreshing #{credential.server_name}: #{e.class}: #{e.message} — not retrying to avoid refresh-token reuse-detection; will re-attempt on the next scheduled run"
    rescue StandardError => e
      failed += 1
      Rails.logger.error "[RefreshMcpOauthTokensJob] Error refreshing #{credential.server_name}: #{e.message}"
    end

    schedule_retry(retry_ids, 1) if retry_ids.any?

    if refreshed > 0 || failed > 0
      Rails.logger.info "[RefreshMcpOauthTokensJob] Refreshed #{refreshed} token(s), #{failed} failure(s)"
    end
  end

  def perform_retry(credential_ids, attempt)
    refreshed = 0
    still_failing_ids = []

    McpOauthCredential.where(id: credential_ids).find_each do |credential|
      credential.with_lock do
        # Re-check inside lock — the token may have been refreshed (or become
        # unrefreshable) since this retry was scheduled
        next unless credential.expiring_soon?(REFRESH_WINDOW)
        next unless credential.can_refresh?

        if credential.refresh!
          refreshed += 1
        else
          Rails.logger.warn "[RefreshMcpOauthTokensJob] Failed to refresh token for #{credential.server_name} (#{credential.credential_key}) on retry #{attempt}"
        end
      end
    rescue *RETRYABLE_REFRESH_ERRORS => e
      still_failing_ids << credential.id
      if attempt < MAX_RETRIES
        Rails.logger.info "[RefreshMcpOauthTokensJob] Transient error refreshing #{credential.server_name} on retry #{attempt}: #{e.class}: #{e.message} (will retry)"
      else
        Rails.logger.error "[RefreshMcpOauthTokensJob] Token refresh for #{credential.server_name} failed after #{MAX_RETRIES} retries: #{e.class}: #{e.message}"
      end
    rescue *AMBIGUOUS_REFRESH_ERRORS => e
      Rails.logger.info "[RefreshMcpOauthTokensJob] Ambiguous network failure refreshing #{credential.server_name} on retry #{attempt}: #{e.class}: #{e.message} — not retrying; deferring to the next scheduled run"
    rescue StandardError => e
      Rails.logger.error "[RefreshMcpOauthTokensJob] Error refreshing #{credential.server_name} on retry #{attempt}: #{e.message}"
    end

    schedule_retry(still_failing_ids, attempt + 1) if still_failing_ids.any? && attempt < MAX_RETRIES

    Rails.logger.info "[RefreshMcpOauthTokensJob] Retry #{attempt}/#{MAX_RETRIES}: #{refreshed} refreshed, #{still_failing_ids.size} still failing"
  end

  def schedule_retry(credential_ids, attempt)
    wait = RETRY_BACKOFF * (2**(attempt - 1))
    Rails.logger.info "[RefreshMcpOauthTokensJob] #{credential_ids.size} credential(s) failed transiently, scheduling retry #{attempt}/#{MAX_RETRIES} in #{wait.to_i}s"
    self.class.set(wait: wait).perform_later(retry_credential_ids: credential_ids, attempt: attempt)
  end

  def credentials_needing_refresh
    McpOauthCredential.expiring_within(REFRESH_WINDOW)
      .where("expires_at > ?", MAX_EXPIRED_AGE.ago)
      .where("updated_at < ?", PROACTIVE_REFRESH_MIN_INTERVAL.ago)
      .where.not(refresh_token: [ nil, "" ])
      .where.not(token_endpoint: [ nil, "" ])
  end
end
