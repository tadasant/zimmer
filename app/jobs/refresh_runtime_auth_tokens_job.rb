# frozen_string_literal: true

# Proactively refreshes login-credential tokens for every agent runtime before
# they expire.
#
# Runs on a GoodJob cron and fans out across every registered
# RuntimeAuthProvider (Claude Code today; Codex via #3780). For each runtime it
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
    # Auto-adopt filesystem identity changes before syncing tokens.
    # If the operator manually switched the runtime's CLI to a different known
    # account, this updates the DB to match the filesystem so the subsequent
    # sync targets the right account.
    provider.reconcile_filesystem_identity!

    # Sync filesystem tokens for the current account before refreshing.
    # The CLI may have rotated the refresh token on the filesystem, making
    # the DB copy stale. Without this sync, the job sends a revoked token
    # to the token server and fails repeatedly.
    provider.sync_current_account_tokens!

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
          if result.error == :needs_reauth
            # The account is already marked needs_reauth and rotated out of the
            # active pool — this is a known-permanent, gracefully-handled outcome
            # (the human re-authenticates to recover). Log at .warn, not .error,
            # so it does not page on a recoverable, non-alerting condition.
            Rails.logger.warn "[RefreshRuntimeAuthTokens] Permanent failure for #{account.email}, marked needs_reauth"
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
