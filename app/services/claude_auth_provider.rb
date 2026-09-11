# frozen_string_literal: true

# ClaudeAuthProvider — the RuntimeAuthProvider for Claude Code.
#
# Owns every Anthropic-specific constant for the login-credential lifecycle (the
# OAuth token endpoint and the OAuth client ID) and implements the provider
# contract by delegating to the workhorses that already manage the Claude account
# pool:
#
#   - ClaudeAccount          — the account pool, token storage, and refresh_token!
#   - AccountRotationService — which account is current, and rotating between them
#
# These constants are the single source of truth: ClaudeAccount,
# AccountRotationService, and the claude_accounts rake task all reference
# ClaudeAuthProvider::* rather than redefining their own copies.
class ClaudeAuthProvider < RuntimeAuthProvider
  RUNTIME = "claude_code"

  # Anthropic OAuth token endpoint and the Claude Code CLI's OAuth client ID.
  TOKEN_ENDPOINT = "https://platform.claude.com/v1/oauth/token"
  CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

  # Access tokens live 8 hours and Zimmer is the only thing that refreshes them,
  # so the pool is swept every 5 minutes to re-mint anything expiring soon.
  ROTATION_INTERVAL = 5.minutes

  def runtime
    RUNTIME
  end

  def accounts
    ClaudeAccount.for_runtime(RUNTIME)
  end

  def current_account
    accounts.find_by(is_current: true)
  end

  def select_account_for(_session)
    current_account || accounts.available.first
  end

  # Refresh the account's access token via Anthropic's OAuth endpoint.
  # @return [RuntimeAuthProvider::Result]
  def refresh!(account)
    if account.refresh_token!
      Result.new(ok: true, error: nil)
    else
      Result.new(ok: false, error: account.reload.last_refresh_failure_reason)
    end
  end

  # Make sure a usable account is current and its token is fresh before a session
  # spawns.
  #
  # That is ALL this does. The session receives the account's access token
  # through CLAUDE_CODE_OAUTH_TOKEN and reads no credential file, so nothing is
  # written to disk here and the per-session working_directory is unused.
  #
  # @return [ClaudeAccount, nil] the active account, or nil if none is available
  def inject_for_session!(_session = nil, _working_directory = nil)
    AccountRotationService.new.ensure_active_account!
  end

  # Activate a validated account by routing through AccountRotationService so a
  # manual switch (or safe-delete fallback) takes exactly the same activation
  # path as an automatic rotation: mark current in the DB, take a quota snapshot.
  def activate!(account)
    AccountRotationService.new.activate!(account, snapshot_trigger: "manual_switch")
    account
  end

  def rotation_interval
    ROTATION_INTERVAL
  end

  # --- Token-refresh dispatcher hooks (used by RefreshRuntimeAuthTokensJob) ---
  #
  # Zimmer implements NEITHER filesystem hook for Claude Code, and the inherited
  # no-ops are the behaviour:
  #
  #   * #reconcile_filesystem_identity! — adopting an identity off ~/.claude.json,
  #     a container-local file a replacement destroys while keeping the tokens, is
  #     how a stale identity got adopted over a correct one on a five-minute timer
  #     (#618, addendum B).
  #   * #sync_current_account_tokens! — no session holds a refresh token or writes
  #     a credentials file, so there is nothing on disk the DB does not already
  #     have, and reading one back would reintroduce the second source of truth
  #     #618 removed.
  #
  # Codex still implements both against its own auth.json, which its CLI owns.

  # Accounts stuck in needs_reauth that still hold a refresh token worth retrying.
  def needs_reauth_recovery_candidates
    accounts.needs_reauth.where.not(oauth_config: {}).to_a.select(&:can_refresh_token?)
  end

  # Attempt to recover a needs_reauth account by probing its refresh token.
  # Accounts may be recoverable after manual re-authentication or if the original
  # failure was transient and a rotation cascade prematurely marked them.
  #
  # @return [Boolean] true if the account was recovered to active
  def recover_needs_reauth(account)
    return false unless account.needs_reauth? && account.can_refresh_token?

    recovered = false
    account.with_lock do
      next unless account.needs_reauth? && account.can_refresh_token?

      # Temporarily reset status so refresh_token! isn't blocked by status checks.
      account.update_columns(status: ClaudeAccount.statuses[:active])

      # recovery_probe: true keeps the expected probe failure (the token is still
      # dead until a human re-auths) at .info instead of re-tripping the ERROR alert.
      if account.refresh_token!(recovery_probe: true)
        recovered = true
      else
        # Refresh failed — restore needs_reauth (refresh_token! may already have
        # set it for a permanent failure).
        account.reload
        account.update_columns(status: ClaudeAccount.statuses[:needs_reauth]) unless account.needs_reauth?
      end
    end
    recovered
  rescue => e
    Rails.logger.info "[ClaudeAuthProvider] Recovery error for #{account.email}: #{e.message}"
    account.update_columns(status: ClaudeAccount.statuses[:needs_reauth]) rescue nil
    false
  end

  # Rotate to the next available account after the current one stopped working.
  # @return [Hash] { success:, account: } or { success: false, reason: }
  def rotate_for_quota!(triggered_by: nil, reason: "quota_exceeded", expected_current_email: nil)
    AccountRotationService.new.rotate!(
      reason: reason,
      triggered_by: triggered_by,
      expected_current_email: expected_current_email
    )
  end
end
