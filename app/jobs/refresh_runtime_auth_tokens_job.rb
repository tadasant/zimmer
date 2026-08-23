# frozen_string_literal: true

# Proactively refreshes login-credential tokens for every agent runtime before
# they expire.
#
# Runs on a GoodJob cron and fans out across every registered
# RuntimeAuthProvider (Claude Code today; Codex via pulsemcp/pulsemcp#3780). For each runtime it
# reconciles the filesystem identity, syncs the current account's tokens, recovers
# accounts stuck in needs_reauth, and refreshes any account whose token expires
# within REFRESH_THRESHOLD. All runtime-specific behavior (token endpoint, refresh
# semantics, recovery) lives behind the provider — this job is runtime-agnostic.
#
# Cadence: each provider declares its sweep cadence via #rotation_interval. The
# cron entry runs at the minimum interval across runtimes (5 minutes today, which
# matches Claude's rotation_interval), and the dispatcher sweeps every registered
# runtime on each tick.
#
# Transient failure handling: When a refresh fails but the account is not
# permanently broken (provider reports :transient rather than :needs_reauth), the
# job schedules a per-runtime follow-up retry with exponential backoff. Only after
# all retries are exhausted is the failure logged at .error level.
class RefreshRuntimeAuthTokensJob < ApplicationJob
  include DatabaseRetry
  queue_as :default

  # Only refresh tokens expiring within this window
  REFRESH_THRESHOLD = 15.minutes

  # Retry configuration for transient failures (exponential backoff: 2, 4, 8 min)
  MAX_RETRIES = 3
  RETRY_BACKOFF = 2.minutes

  # @param retry_account_ids [Array<Integer>, nil] account IDs to retry after transient failure
  # @param attempt [Integer, nil] current retry attempt (1-based)
  # @param runtime [String, nil] runtime identifier for the retry batch (resolves the provider)
  def perform(retry_account_ids: nil, attempt: nil, runtime: nil)
    if retry_account_ids.present?
      perform_retry(retry_account_ids, attempt, RuntimeAuthProvider.for(runtime))
    else
      RuntimeAuthProvider.registered.each { |provider| perform_scheduled_refresh(provider) }
    end
  end

  private

  def perform_scheduled_refresh(provider)
    # Auto-adopt filesystem identity changes before syncing tokens, for the
    # runtimes that still have one. Claude Code does not: it no longer implements
    # the hook, because adopting an identity off a container-local file on a
    # five-minute timer is how a stale identity got adopted over a correct one
    # (issue #618, addendum B). Codex still reconciles its own auth.json here.
    provider.reconcile_filesystem_identity!

    # Repair a corrupt credentials file before anything reads it. The CLI can
    # blank its own tokens in place (issue #618); left alone, the file stays
    # broken, the sync below declines to adopt it every five minutes, and every
    # session on the worker reports "Not logged in" until a human intervenes.
    # Rewriting it from the DB copy costs nothing when there is nothing to repair.
    self_heal_credentials(provider)

    # Sync filesystem tokens for the current account before refreshing.
    # The CLI may have rotated the refresh token on the filesystem, making
    # the DB copy stale. Without this sync, the job sends a revoked token
    # to the token server and fails repeatedly.
    sync_outcome = provider.sync_current_account_tokens!

    # Attempt to recover needs_reauth accounts whose tokens may have been
    # fixed by re-authentication or manual intervention.
    attempt_needs_reauth_recovery(provider)

    accounts = accounts_needing_refresh(provider)
    refreshed = 0
    failed = 0
    retry_ids = []

    accounts.each do |account|
      account.with_lock do
        # Re-check inside lock — another worker may have already refreshed
        next unless account.can_refresh_token? && account.token_expiring_soon?(REFRESH_THRESHOLD)

        result = provider.refresh!(account)
        if result.ok?
          refreshed += 1
        else
          failed += 1
          case result.error
          when :needs_reauth
            # The account is already marked needs_reauth and rotated out of the
            # active pool — this is a known-permanent, gracefully-handled outcome
            # (the human re-authenticates to recover). Log at .warn, not .error,
            # so it does not page on a recoverable, non-alerting condition.
            Rails.logger.warn "[RefreshRuntimeAuthTokens] Permanent failure for #{account.email}, marked needs_reauth"
          when :stale
            # The vendor rejected the token VALUE. A retry would present the same
            # value and be rejected the same way, so the ladder is three wasted
            # requests that end in an .error nobody can act on. Wait for the next
            # sweep instead — by then a filesystem sync or another caller's
            # refresh may have moved the row on. See ClaudeAccount#530 handling.
            #
            # Unless nothing can move the row on. That wait has a liveness
            # assumption, and the corruption guard on the sync is exactly the
            # thing that breaks it: a sync being skipped every sweep will never
            # deliver the newer value the wait is waiting for, and the "wait" is
            # a metronome that ran for three hours on 2026-08-22. When the sync
            # is the thing that is stuck, this is terminal and needs a human.
            # `sync_outcome` describes the CURRENT account's sync and nothing
            # else — a non-current account is never synced from the shared file,
            # so a corrupt file says nothing about why its refresh was rejected.
            if sync_outcome == :corrupt && account.is_current?
              escalate_wedged_stale_refresh(account)
            else
              Rails.logger.warn "[RefreshRuntimeAuthTokens] #{account.email} presented a spent refresh token value; " \
                "not retrying it with the same value, waiting for the next sweep"
            end
          else
            retry_ids << account.id
          end
        end
      end
    rescue => e
      failed += 1
      retry_ids << account.id
      Rails.logger.info "[RefreshRuntimeAuthTokens] Error refreshing #{account.email}: #{e.message} (will retry)"
    end

    if retry_ids.any?
      Rails.logger.info "[RefreshRuntimeAuthTokens] #{retry_ids.size} #{provider.runtime} account(s) failed transiently, scheduling retry 1/#{MAX_RETRIES} in #{RETRY_BACKOFF.to_i}s"
      self.class.set(wait: RETRY_BACKOFF).perform_later(
        retry_account_ids: retry_ids,
        attempt: 1,
        runtime: provider.runtime
      )
    end

    Rails.logger.info "[RefreshRuntimeAuthTokens] Completed #{provider.runtime}: #{refreshed} refreshed, #{failed} failed"
  end

  def perform_retry(account_ids, attempt, provider)
    refreshed = 0
    still_failing_ids = []

    provider.accounts.where(id: account_ids).find_each do |account|
      next unless account.can_refresh_token?
      next if account.needs_reauth?

      account.with_lock do
        # Re-check inside lock — state may have changed since the pre-check
        next unless account.can_refresh_token?
        next if account.needs_reauth?

        result = provider.refresh!(account)
        if result.ok?
          refreshed += 1
        elsif result.error == :needs_reauth
          # Known-permanent, gracefully-handled outcome (account already marked
          # needs_reauth and rotated out). Log at .warn, not .error — see the
          # matching branch in #perform.
          Rails.logger.warn "[RefreshRuntimeAuthTokens] Permanent failure for #{account.email} on retry #{attempt}, marked needs_reauth"
        elsif result.error == :stale
          # Same reasoning as #perform: the value is spent, so the rest of the
          # ladder would present it again. Stop climbing.
          Rails.logger.warn "[RefreshRuntimeAuthTokens] #{account.email} presented a spent refresh token value on retry #{attempt}; " \
            "abandoning the retry ladder rather than replaying it"
        else
          still_failing_ids << account.id
        end
      end
    rescue => e
      still_failing_ids << account.id
      if attempt < MAX_RETRIES
        Rails.logger.info "[RefreshRuntimeAuthTokens] Retry error for #{account.email}: #{e.message} (will retry)"
      else
        Rails.logger.error "[RefreshRuntimeAuthTokens] Retry error for #{account.email}: #{e.message} (retries exhausted)"
      end
    end

    if still_failing_ids.any? && attempt < MAX_RETRIES
      wait = RETRY_BACKOFF * (2**attempt)
      Rails.logger.info "[RefreshRuntimeAuthTokens] #{still_failing_ids.size} #{provider.runtime} still failing, scheduling retry #{attempt + 1}/#{MAX_RETRIES} in #{wait.to_i}s"
      self.class.set(wait: wait).perform_later(
        retry_account_ids: still_failing_ids,
        attempt: attempt + 1,
        runtime: provider.runtime
      )
    elsif still_failing_ids.any?
      still_failing_ids.each do |id|
        account = provider.accounts.find_by(id: id)
        Rails.logger.error "[RefreshRuntimeAuthTokens] Token refresh for #{account&.email || id} failed after #{MAX_RETRIES} retries"
      end
    end

    Rails.logger.info "[RefreshRuntimeAuthTokens] Retry #{attempt}/#{MAX_RETRIES} (#{provider.runtime}): #{refreshed} refreshed, #{still_failing_ids.size} still failing"
  end

  # Repair a corrupt shared credentials file from the DB, for providers that
  # have one. Never fatal to the sweep — a failed repair is reported and the
  # sweep continues, because the accounts that are NOT the current one can still
  # be refreshed while the file is broken.
  def self_heal_credentials(provider)
    return unless provider.runtime == ClaudeAuthProvider::RUNTIME

    outcome, detail = ClaudeCredentialHealth.self_heal!
    return if outcome == :skipped

    if outcome == :healed
      Rails.logger.warn "[RefreshRuntimeAuthTokens] Self-healed the shared credentials file: #{detail}"
    else
      Rails.logger.error "[RefreshRuntimeAuthTokens] Could not self-heal the shared credentials file: #{detail}"
    end
  rescue => e
    Rails.logger.error "[RefreshRuntimeAuthTokens] Credential self-heal raised: #{e.message}"
  end

  # Both halves of the deadlock are now true at once: the account's stored
  # refresh token is spent, and the one mechanism that could replace it — the
  # filesystem sync — is refusing to run because the file it reads is corrupt.
  # Nothing in Zimmer moves this forward, so say so at .error (where the alerting
  # pipeline can see it) and raise it to the operator rather than logging another
  # .warn into the same silence the incident produced 126 times an hour.
  def escalate_wedged_stale_refresh(account)
    health = ClaudeCredentialHealth.status
    details = "#{account.email}'s stored refresh token was rejected as spent, and the filesystem sync that would "       "replace it is being skipped because the worker's credentials file is corrupt. #{health.detail} "       "Nothing in Zimmer can move this account forward — re-authenticate it from /quotas."

    Rails.logger.error "[RefreshRuntimeAuthTokens] Auth deadlock for #{account.email}: #{details}"
    AlertService.raise_alert(
      "Claude auth deadlocked: spent refresh token and a corrupt credentials file",
      details: details,
      source: "RefreshRuntimeAuthTokensJob",
      dedup_key: "auth-deadlock:#{account.id}"
    )
  rescue => e
    Rails.logger.error "[RefreshRuntimeAuthTokens] Could not escalate the auth deadlock for #{account.email}: #{e.message}"
  end

  # Attempt to recover accounts stuck in needs_reauth by delegating to the
  # provider's recovery hook. Accounts may be recoverable after manual
  # re-authentication or if the original failure was transient and a rotation
  # cascade prematurely marked them needs_reauth.
  def attempt_needs_reauth_recovery(provider)
    provider.needs_reauth_recovery_candidates.each do |account|
      if provider.recover_needs_reauth(account)
        Rails.logger.info "[RefreshRuntimeAuthTokens] Recovered #{account.email} from needs_reauth"
      else
        Rails.logger.info "[RefreshRuntimeAuthTokens] Recovery attempt failed for #{account.email}, keeping needs_reauth"
      end
    end
  end

  # Finds accounts with tokens expiring within the threshold for a runtime.
  # Uses instance-level filtering since token expiry is stored in a JSONB field
  # and there are only a handful of accounts (~5).
  def accounts_needing_refresh(provider)
    provider.accounts.where.not(oauth_config: {}).to_a.select do |account|
      account.can_refresh_token? && !account.needs_reauth? && account.token_expiring_soon?(REFRESH_THRESHOLD)
    end
  end
end
