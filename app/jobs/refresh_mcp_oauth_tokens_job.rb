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
# intermediate attempts. A retried failure is logged at .error once all retries
# are exhausted; a deferred one once it fails again on the next scheduled run
# (AMBIGUOUS_FAILURE_STREAK_TO_ALERT). Either way a genuinely persistent outage
# stays alertable.
#
# A 429/5xx *answer* from the token endpoint gets the same treatment: the job asks
# #refresh! to raise McpOauthCredential::TransientRefreshFailure instead of
# logging it. A 429 or 503 (normally the provider declining the work) climbs the
# retry ladder like a connection that never opened. Any other 5xx is handled like
# a lost response: no in-band re-send, deferred to the next scheduled run.
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

  # Consecutive ambiguous failures of one credential — a lost response or a
  # 500/502/504 — before the next one logs at .error. Ambiguous failures are never
  # re-sent in-band, so consecutive means consecutive *runs*: one is a blip and
  # logs at .info, a second, 30 minutes later on the next cron run, is an outage
  # that is not clearing. The cron keeps selecting a failing credential (its
  # updated_at is untouched) until MAX_EXPIRED_AGE, so every run after that
  # logs at .error too.
  AMBIGUOUS_FAILURE_STREAK_TO_ALERT = 2

  # Rails cache (Redis) key prefix for that streak, per credential. A successful
  # refresh clears it. Same shape as GithubTriggerPollerJob's streaks.
  AMBIGUOUS_FAILURE_STREAK_KEY_PREFIX = "refresh_mcp_oauth_tokens:ambiguous_failure_streak:"

  # Comfortably beyond the 30-minute cron so one late tick can't reset a streak,
  # short enough that a blip from yesterday doesn't count toward today's.
  AMBIGUOUS_FAILURE_STREAK_TTL = 2.hours

  def self.ambiguous_failure_streak_key(credential_id)
    "#{AMBIGUOUS_FAILURE_STREAK_KEY_PREFIX}#{credential_id}"
  end

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
      # Adopt any token an agent runtime already refreshed (and rotated) on disk
      # before we hit the network. Without this the cron can present a DB refresh
      # token a session rotated away and get invalid_grant on a live credential.
      reconcile_from_runtimes!(credential)

      # Use database-level locking to prevent concurrent refresh attempts
      # from multiple workers racing on the same credential
      credential.with_lock do
        # Re-check inside lock — another worker (or the reconcile above) may have
        # already advanced this token past the refresh window
        next unless credential.expiring_soon?(REFRESH_WINDOW)
        next unless credential.can_refresh?

        if credential.refresh!(raise_on_transient: true)
          refreshed += 1
          clear_ambiguous_failure_streak(credential)
        else
          failed += 1
          Rails.logger.warn "[RefreshMcpOauthTokensJob] Failed to refresh token for #{credential.server_name} (#{credential.credential_key})"
        end
      end
    rescue McpOauthCredential::TransientRefreshFailure => e
      failed += 1
      if e.unprocessed?
        retry_ids << credential.id
        Rails.logger.info "[RefreshMcpOauthTokensJob] Transient token endpoint response refreshing #{credential.server_name}: #{e.message} (will retry)"
      else
        log_ambiguous_failure(credential, "token endpoint response", e.message, "will re-attempt on the next scheduled run")
      end
    rescue *RETRYABLE_REFRESH_ERRORS => e
      failed += 1
      retry_ids << credential.id
      Rails.logger.info "[RefreshMcpOauthTokensJob] Transient error refreshing #{credential.server_name}: #{e.class}: #{e.message} (will retry)"
    rescue *AMBIGUOUS_REFRESH_ERRORS => e
      failed += 1
      log_ambiguous_failure(credential, "network failure", "#{e.class}: #{e.message}", "will re-attempt on the next scheduled run")
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
      # A session may have refreshed this token on disk between the failed attempt
      # and this retry — adopt it so we don't retry against a rotated-away token.
      reconcile_from_runtimes!(credential)

      credential.with_lock do
        # Re-check inside lock — the token may have been refreshed (or become
        # unrefreshable) since this retry was scheduled
        next unless credential.expiring_soon?(REFRESH_WINDOW)
        next unless credential.can_refresh?

        if credential.refresh!(raise_on_transient: true)
          refreshed += 1
          clear_ambiguous_failure_streak(credential)
        else
          Rails.logger.warn "[RefreshMcpOauthTokensJob] Failed to refresh token for #{credential.server_name} (#{credential.credential_key}) on retry #{attempt}"
        end
      end
    rescue McpOauthCredential::TransientRefreshFailure => e
      if !e.unprocessed?
        log_ambiguous_failure(credential, "token endpoint response", "on retry #{attempt}: #{e.message}", "deferring to the next scheduled run")
      elsif attempt < MAX_RETRIES
        still_failing_ids << credential.id
        Rails.logger.info "[RefreshMcpOauthTokensJob] Transient token endpoint response refreshing #{credential.server_name} on retry #{attempt}: #{e.message} (will retry)"
      else
        still_failing_ids << credential.id
        Rails.logger.error "[RefreshMcpOauthTokensJob] Token refresh for #{credential.server_name} failed after #{MAX_RETRIES} retries: #{e.message}"
      end
    rescue *RETRYABLE_REFRESH_ERRORS => e
      still_failing_ids << credential.id
      if attempt < MAX_RETRIES
        Rails.logger.info "[RefreshMcpOauthTokensJob] Transient error refreshing #{credential.server_name} on retry #{attempt}: #{e.class}: #{e.message} (will retry)"
      else
        Rails.logger.error "[RefreshMcpOauthTokensJob] Token refresh for #{credential.server_name} failed after #{MAX_RETRIES} retries: #{e.class}: #{e.message}"
      end
    rescue *AMBIGUOUS_REFRESH_ERRORS => e
      log_ambiguous_failure(credential, "network failure", "on retry #{attempt}: #{e.class}: #{e.message}", "deferring to the next scheduled run")
    rescue StandardError => e
      Rails.logger.error "[RefreshMcpOauthTokensJob] Error refreshing #{credential.server_name} on retry #{attempt}: #{e.message}"
    end

    schedule_retry(still_failing_ids, attempt + 1) if still_failing_ids.any? && attempt < MAX_RETRIES

    Rails.logger.info "[RefreshMcpOauthTokensJob] Retry #{attempt}/#{MAX_RETRIES}: #{refreshed} refreshed, #{still_failing_ids.size} still failing"
  end

  # An ambiguous failure is never re-sent in-band, so the next scheduled run is the
  # only retry, and the streak of consecutive failures decides how loud to be: the
  # first logs at .info, every one from AMBIGUOUS_FAILURE_STREAK_TO_ALERT on at
  # .error. When the cache can't count, it logs at .error — a lost streak must
  # fail loud, never silent.
  def log_ambiguous_failure(credential, kind, detail, deferral)
    streak = bump_ambiguous_failure_streak(credential)
    if streak && streak < AMBIGUOUS_FAILURE_STREAK_TO_ALERT
      Rails.logger.info "[RefreshMcpOauthTokensJob] Ambiguous #{kind} refreshing #{credential.server_name} (#{detail}) — not retrying in-band to avoid refresh-token reuse-detection; #{deferral}"
    else
      Rails.logger.error "[RefreshMcpOauthTokensJob] Token refresh for #{credential.server_name} still failing (ambiguous #{kind}, #{streak ? "#{streak} consecutive runs" : "streak uncounted"}): #{detail}"
    end
  end

  # The new streak length, or nil when the cache could not be reached.
  def bump_ambiguous_failure_streak(credential)
    key = self.class.ambiguous_failure_streak_key(credential.id)
    streak = Rails.cache.read(key).to_i + 1
    Rails.cache.write(key, streak, expires_in: AMBIGUOUS_FAILURE_STREAK_TTL)
    streak
  rescue StandardError => e
    Rails.logger.warn "[RefreshMcpOauthTokensJob] Failed to track ambiguous-failure streak for #{credential.server_name}: #{e.message}"
    nil
  end

  # Rescued so a cache hiccup never turns a refresh that worked into an error.
  def clear_ambiguous_failure_streak(credential)
    Rails.cache.delete(self.class.ambiguous_failure_streak_key(credential.id))
  rescue StandardError => e
    Rails.logger.warn "[RefreshMcpOauthTokensJob] Failed to clear ambiguous-failure streak for #{credential.server_name}: #{e.message}"
  end

  def schedule_retry(credential_ids, attempt)
    wait = RETRY_BACKOFF * (2**(attempt - 1))
    Rails.logger.info "[RefreshMcpOauthTokensJob] #{credential_ids.size} credential(s) failed transiently, scheduling retry #{attempt}/#{MAX_RETRIES} in #{wait.to_i}s"
    self.class.set(wait: wait).perform_later(retry_credential_ids: credential_ids, attempt: attempt)
  end

  # Adopts a token any runtime already rotated on disk before this job hits the
  # network with the DB's copy.
  #
  # **Every** runtime, not just the session's or just Claude Code's. An
  # McpOauthCredential row is runtime-agnostic — one row per server config — but
  # each runtime keeps its own copy, and both Claude Code and Pi refresh MCP
  # tokens mid-session. This job has no session and therefore no runtime, so
  # reading only one store is how a rotation performed by a session on another
  # runtime gets burned: the cron presents the rotated-away DB token, the
  # provider's reuse detection answers `invalid_grant`, and the credential is
  # dead until a human re-authorizes it. Codex is written-not-trusted (see
  # CodexMcpCredentialWriter) so its store never holds anything newer, which
  # makes including it a no-op rather than an exception to carve out.
  #
  # Order does not matter. Adoption requires a strictly later access-token
  # expiry than the DB row *currently* holds, so each store is compared against
  # the outcome of the previous one and the newest pair wins whichever order
  # they are read in.
  # Reconciliation is best-effort, and the rescue is not decoration. #reconcile!
  # swallows its own failures, but building a writer and asking it
  # #runtime_key_for happen outside it — and the memoized list means a writer
  # class that raises on construction raises again for every credential, landing
  # in the caller's `rescue StandardError` that logs at .error. That pages
  # #alerts for a condition the next run resolves, which is exactly what the
  # transient-failure handling at the top of this file exists to avoid.
  def reconcile_from_runtimes!(credential)
    runtime_reconcilers.each do |writer, reconciler|
      reconciler.reconcile!(credential, runtime_key: writer.runtime_key_for(credential))
    end
  rescue StandardError => e
    Rails.logger.warn "[RefreshMcpOauthTokensJob] Skipped runtime reconciliation for #{credential.server_name}: #{e.class}: #{e.message}"
  end

  # One writer/reconciler pair per registered runtime that has a HOST-GLOBAL
  # credential store, built once per job run.
  #
  # Claude Code is skipped, and that is not a gap. Its store is per-session (a
  # `.credentials.json` inside each session's CLAUDE_CONFIG_DIR, issue #618), so
  # this sweep has no single file to read; what it used to read —
  # ~/.claude/.credentials.json — is a file no session writes any more, and
  # adopting from it could only ever resurrect a fossil. The capture happens
  # instead at every spawn and follow-up, where McpOauthCredentialInjector builds
  # a reconciler over THAT session's writer.
  # Reading is lazy inside the reconciler, so a
  # listable store (Codex) is read once for the whole run however many
  # credentials ask. Pi's is probed per key, and its keys are server names,
  # so it costs one `node` spawn per distinct server — bounded by the throttle on
  # #credentials_needing_refresh rather than by the size of the table.
  def runtime_reconcilers
    @runtime_reconcilers ||= RuntimeRegistry.mcp_credential_writer_classes
      .reject(&:session_scoped_store?)
      .map do |writer_class|
        writer = writer_class.new
        [ writer, McpOauthRuntimeReconciler.new(writer) ]
      end
  end

  def credentials_needing_refresh
    McpOauthCredential.expiring_within(REFRESH_WINDOW)
      .where("expires_at > ?", MAX_EXPIRED_AGE.ago)
      .where("updated_at < ?", PROACTIVE_REFRESH_MIN_INTERVAL.ago)
      .where.not(refresh_token: [ nil, "" ])
      .where.not(token_endpoint: [ nil, "" ])
  end
end
