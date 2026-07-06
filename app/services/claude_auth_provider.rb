# frozen_string_literal: true

# ClaudeAuthProvider — the RuntimeAuthProvider for Claude Code.
#
# Owns every Anthropic-specific constant for the login-credential lifecycle (the
# OAuth token endpoint, the OAuth client ID, and the canonical filesystem paths
# for ~/.claude.json and ~/.claude/.credentials.json) and implements the provider
# contract by delegating to the workhorses that already manage the Claude account
# pool:
#
#   - ClaudeAccount        — the account pool, token storage, and refresh_token!
#   - AccountRotationService — filesystem ↔ DB reconciliation and before-spawn
#                              credential writes
#
# These constants are the single source of truth: ClaudeAccount,
# AccountRotationService, and the claude_accounts rake task all reference
# ClaudeAuthProvider::* rather than redefining their own copies.
class ClaudeAuthProvider < RuntimeAuthProvider
  RUNTIME = "claude_code"

  # Anthropic OAuth token endpoint and the Claude Code CLI's OAuth client ID.
  TOKEN_ENDPOINT = "https://platform.claude.com/v1/oauth/token"
  CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

  # Canonical filesystem locations the Claude CLI reads its identity and OAuth
  # tokens from. All sessions on a worker share this single identity.
  CLAUDE_JSON_PATH = File.join(Dir.home, ".claude.json")
  CREDENTIALS_JSON_PATH = File.join(Dir.home, ".claude", ".credentials.json")

  # Claude's CLI rotates refresh tokens on its own during sessions, so AO sweeps
  # the pool every 5 minutes to refresh anything expiring soon.
  ROTATION_INTERVAL = 5.minutes

  # Sidecar marker recording which account AO last wrote into the SHARED
  # ~/.claude/.credentials.json. It is co-located with the credentials file (same
  # directory, which in production is a bind mount shared by the web and worker
  # containers) so every reader agrees on "whose tokens are on disk" — unlike
  # ~/.claude.json, which is container-local and diverges across containers.
  #
  # Derived from CREDENTIALS_JSON_PATH at call time (not a frozen constant) so a
  # test that redirects CREDENTIALS_JSON_PATH to a temp dir automatically
  # relocates the marker alongside it. See ClaudeAccount.credentials_owner_email.
  def self.credentials_owner_path
    File.join(File.dirname(CREDENTIALS_JSON_PATH), ".ao-credentials-owner.json")
  end

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
      Result.new(ok: false, error: account.reload.needs_reauth? ? :needs_reauth : :transient)
    end
  end

  # Reconcile filesystem ↔ DB and write the active account's credentials to
  # ~/.claude.json + ~/.claude/.credentials.json before a session spawns. Claude
  # writes to a fixed home-dir location shared by all sessions, so the per-session
  # working_directory is not used.
  #
  # @return [ClaudeAccount, nil] the active account, or nil if none is available
  def inject_for_session!(_session = nil, _working_directory = nil)
    AccountRotationService.new.ensure_active_account!
  end

  # Activate a validated account by routing through AccountRotationService so a
  # manual switch (or safe-delete fallback) takes exactly the same activation
  # path as an automatic rotation: write ~/.claude.json + ~/.claude/.credentials.json,
  # mark current in the DB, take a quota snapshot.
  def activate!(account)
    AccountRotationService.new.activate!(account, snapshot_trigger: "manual_switch")
    account
  end

  def rotation_interval
    ROTATION_INTERVAL
  end

  # --- Token-refresh dispatcher hooks (used by RefreshRuntimeAuthTokensJob) ---

  # Adopt a manual `claude /login` filesystem switch into the DB before syncing
  # tokens, so the subsequent sync targets the right account.
  def reconcile_filesystem_identity!
    AccountRotationService.new.reconcile_with_filesystem!
  end

  # Sync filesystem tokens for the current account back to the DB. The CLI may
  # have rotated the refresh token on disk, making the DB copy stale.
  def sync_current_account_tokens!
    current = current_account
    return unless current

    current.sync_tokens_from_filesystem!
    Rails.logger.info "[ClaudeAuthProvider] Synced filesystem tokens for current account #{current.email}"
  rescue => e
    Rails.logger.info "[ClaudeAuthProvider] Failed to sync filesystem tokens: #{e.message}"
  end

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

  # Rotate to the next available account after the current one hit its quota.
  # @return [Hash] { success:, account: } or { success: false, reason: }
  def rotate_for_quota!(triggered_by: nil)
    AccountRotationService.new.rotate!(reason: "quota_exceeded", triggered_by: triggered_by)
  end
end
