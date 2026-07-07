# frozen_string_literal: true

# CodexAuthProvider — the RuntimeAuthProvider for the OpenAI Codex CLI.
#
# Owns every Codex/OpenAI-specific constant for the login-credential lifecycle
# (the OAuth token endpoint, the OAuth client ID, and the canonical filesystem
# path for ~/.codex/auth.json) and implements the provider contract over the
# shared ClaudeAccount pool, scoped to the "codex" runtime.
#
# Codex supports two credential kinds, both pooled the same way Claude accounts
# are:
#
#   - ChatGPT OAuth (preferred) — captured via `codex login --device-auth`, stored
#     as the full auth.json envelope under oauth_config["auth_json"]. Zimmer refreshes
#     these tokens against OpenAI's token endpoint and rotates between accounts
#     when one hits a usage quota.
#   - OPENAI_API_KEY (fallback) — stored as oauth_config["api_key"]. Static keys
#     never expire and have nothing to refresh; Zimmer simply writes them to auth.json.
#
# Unlike Claude, Codex has no separate AccountRotationService — the filesystem is
# a single shared ~/.codex/auth.json (like ~/.claude.json), so this provider owns
# its own before-spawn reconciliation and quota-rotation logic. The Codex CLI
# refreshes the active account's tokens in place and rotates its refresh_token, so
# the provider syncs filesystem tokens back to the DB before refreshing to avoid
# replaying a spent refresh token.
class CodexAuthProvider < RuntimeAuthProvider
  RUNTIME = "codex"

  # OpenAI OAuth token endpoint and the Codex CLI's OAuth client ID (matching the
  # Codex CLI's own REFRESH_TOKEN_URL / CLIENT_ID).
  TOKEN_ENDPOINT = "https://auth.openai.com/oauth/token"
  CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"

  # Canonical filesystem location the Codex CLI reads its identity and tokens
  # from, resolved through the shared CodexHome resolver so the auth provider,
  # transcript source, MCP credential writer, and spawn environment all agree on
  # where Codex state lives (CODEX_HOME overrides the default ~/.codex).
  CODEX_HOME = CodexHome.path
  AUTH_JSON_PATH = CodexHome.auth_json_path

  # auth.json carries no explicit access-token expiry. Zimmer refreshes pool accounts
  # on a soft TTL measured from last_refresh — long enough that the sweep skips
  # most ticks (refreshing each account roughly once per day) while keeping
  # refresh tokens warm. The CLI handles intra-session freshness on its own.
  TOKEN_TTL = 24.hours

  # How often the refresh dispatcher should sweep the Codex pool. The dispatcher
  # runs at the minimum cadence across runtimes (5 min today, Claude's), but the
  # TTL above means a Codex account only becomes "expiring soon" near the end of
  # its 24h window, so the vast majority of ticks are no-ops for Codex.
  ROTATION_INTERVAL = 24.hours

  def initialize
    @logger = StructuredLogger.new({ service: "CodexAuthProvider" })
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

  def rotation_interval
    ROTATION_INTERVAL
  end

  # Refresh the account's tokens via OpenAI's OAuth endpoint. API-key accounts
  # have nothing to refresh and report a healthy no-op.
  # @return [RuntimeAuthProvider::Result]
  def refresh!(account)
    return Result.new(ok: true, error: nil) if account.codex_api_key_account?

    if account.refresh_token!
      Result.new(ok: true, error: nil)
    else
      Result.new(ok: false, error: account.reload.needs_reauth? ? :needs_reauth : :transient)
    end
  end

  # Reconcile filesystem ↔ DB and write the active account's credentials to
  # ~/.codex/auth.json before a session spawns. Codex writes to a fixed home-dir
  # location shared by all sessions, so the per-session working_directory is unused.
  #
  # @return [ClaudeAccount, nil] the active account, or nil if none is available
  def inject_for_session!(_session = nil, _working_directory = nil)
    ensure_active_account!
  end

  # Activate a validated account: capture the outgoing identity's CLI-rotated
  # tokens, write this account's credentials to ~/.codex/auth.json, and mark it
  # current in the DB. Drives the manual switch and safe-delete paths. Codex has
  # no quota-probe service, so (unlike Claude) no snapshot is taken here.
  def activate!(account)
    capture_outgoing_filesystem_tokens(except: account)
    account.write_codex_auth_to_filesystem!
    account.mark_current!
    @logger.info("Activated codex account", email: account.email)
    account
  end

  # --- Token-refresh dispatcher hooks (used by RefreshRuntimeAuthTokensJob) ---

  # Adopt a manual `codex login` filesystem switch into the DB before syncing
  # tokens, so the subsequent sync targets the right account. Returns the adopted
  # account, or nil if no adoption occurred.
  def reconcile_filesystem_identity!
    current = current_account
    return nil unless current
    return nil if auth_file_matches?(current)

    fs_account = detect_filesystem_account
    return nil unless fs_account
    return nil if fs_account.id == current.id
    return nil unless fs_account.active? && fs_account.has_valid_config?
    return nil unless filesystem_newer_than_db?(current)

    @logger.info("CLI manually switched to different codex account, adopting filesystem identity",
      db_current: current.email, fs_account: fs_account.email)
    fs_account.mark_current!
    fs_account.sync_codex_tokens_from_filesystem!
    fs_account
  end

  # Sync filesystem tokens for the current account back to the DB. The CLI may
  # have rotated the refresh token on disk, making the DB copy stale.
  def sync_current_account_tokens!
    current = current_account
    return unless current

    current.sync_codex_tokens_from_filesystem!
    @logger.info("Synced filesystem tokens for current codex account", email: current.email)
  rescue => e
    @logger.info("Failed to sync codex filesystem tokens", error: e.message)
  end

  # Accounts stuck in needs_reauth that still hold a refresh token worth retrying.
  def needs_reauth_recovery_candidates
    accounts.needs_reauth.where.not(oauth_config: {}).to_a.select(&:can_refresh_token?)
  end

  # Attempt to recover a needs_reauth account by probing its refresh token.
  # Mirrors ClaudeAuthProvider#recover_needs_reauth.
  #
  # @return [Boolean] true if the account was recovered to active
  def recover_needs_reauth(account)
    return false unless account.needs_reauth? && account.can_refresh_token?

    recovered = false
    account.with_lock do
      next unless account.needs_reauth? && account.can_refresh_token?

      account.update_columns(status: ClaudeAccount.statuses[:active])

      # recovery_probe: true keeps the expected probe failure (the token is still
      # dead until a human re-auths) at .info instead of re-tripping the ERROR alert.
      if account.refresh_token!(recovery_probe: true)
        recovered = true
      else
        account.reload
        account.update_columns(status: ClaudeAccount.statuses[:needs_reauth]) unless account.needs_reauth?
      end
    end
    recovered
  rescue => e
    @logger.info("Recovery error for codex account", email: account.email, error: e.message)
    account.update_columns(status: ClaudeAccount.statuses[:needs_reauth]) rescue nil
    false
  end

  # Rotate to the next available account after the current one hit its quota.
  # @return [Hash] { success:, account: } or { success: false, reason: }
  def rotate_for_quota!(triggered_by: nil)
    current = current_account

    if current
      sync_current_tokens(current)
      current.mark_quota_exceeded!
      @logger.info("Marked codex account as quota_exceeded", email: current.email)
    end

    result = activate_next_account(exclude_ids: [ current&.id ].compact)

    if result[:success]
      event = AccountRotationEvent.create(
        rotated_from: current,
        rotated_to: result[:account],
        reason: "quota_exceeded",
        source: "automatic",
        triggered_by: triggered_by
      )
      @logger.warn("Failed to log codex rotation event", errors: event.errors.full_messages) unless event.persisted?
    end

    result
  end

  private

  # Ensure an active codex account's auth.json is on disk before a spawn. Adopts
  # a manual CLI switch when one is detected, otherwise writes the DB-current
  # account's credentials to disk and refreshes them if expiring.
  def ensure_active_account!
    current = current_account

    if current&.active? && current&.has_valid_config?
      if auth_file_matches?(current)
        sync_current_tokens(current)
      else
        adopted = reconcile_filesystem_identity!
        if adopted
          current = adopted
        else
          capture_outgoing_filesystem_tokens(except: current)
          @logger.info("Codex auth.json mismatch, syncing DB-current account to disk", email: current.email)
          current.write_codex_auth_to_filesystem!
        end
      end

      if current.token_expired? || current.token_expiring_soon?
        @logger.info("Refreshing expired/expiring tokens for current codex account", email: current.email)
        if current.refresh_token!
          current.write_codex_auth_to_filesystem!
        else
          @logger.warn("Codex token refresh failed for current account", email: current.email)
        end
      end

      return current
    end

    account = accounts.available.first
    return nil unless account

    ensure_fresh_tokens!(account)
    account.write_codex_auth_to_filesystem!
    account.mark_current!
    @logger.info("Set initial active codex account", email: account.email)
    account
  end

  # Find and activate the next available account, validating OAuth tokens by
  # probing OpenAI's token endpoint before writing them to disk. API-key accounts
  # have no token to probe and are accepted as-is. Skips accounts that fail
  # validation and tries the next one.
  def activate_next_account(exclude_ids:)
    next_account = accounts.available.where.not(id: exclude_ids).first

    unless next_account
      @logger.warn("No available codex accounts for rotation")
      return { success: false, reason: "no_available_accounts" }
    end

    if !next_account.codex_api_key_account?
      unless next_account.can_refresh_token?
        @logger.warn("Codex account has no refresh token, skipping during rotation", email: next_account.email)
        return activate_next_account(exclude_ids: exclude_ids + [ next_account.id ])
      end

      @logger.info("Validating codex tokens before activation", email: next_account.email)
      unless next_account.refresh_token!
        @logger.warn("Codex token validation failed during rotation, skipping account", email: next_account.email)
        return activate_next_account(exclude_ids: exclude_ids + [ next_account.id ])
      end
    end

    capture_outgoing_filesystem_tokens(except: next_account)
    next_account.write_codex_auth_to_filesystem!
    next_account.mark_current!

    @logger.info("Rotated to codex account", email: next_account.email, priority: next_account.priority)
    { success: true, account: next_account }
  end

  def sync_current_tokens(account)
    account.sync_codex_tokens_from_filesystem!
    @logger.info("Synced codex filesystem tokens to DB", email: account.email)
  rescue => e
    @logger.warn("Failed to sync codex filesystem tokens", email: account.email, error: e.message)
  end

  # Capture the CLI-rotated tokens belonging to whoever currently owns the
  # filesystem auth.json, so they aren't lost when we overwrite the file with a
  # different account's credentials.
  def capture_outgoing_filesystem_tokens(except:)
    fs_account = detect_filesystem_account
    return if fs_account.nil?
    return if except && fs_account.id == except.id

    fs_account.sync_codex_tokens_from_filesystem!
    @logger.info("Captured outgoing codex filesystem tokens to DB", email: fs_account.email)
  rescue => e
    @logger.warn("Failed to capture outgoing codex filesystem tokens", error: e.message)
  end

  def ensure_fresh_tokens!(account)
    return unless account.token_expired? || account.token_expiring_soon?
    return unless account.can_refresh_token?

    @logger.info("Refreshing expired/expiring codex tokens", email: account.email)
    account.refresh_token!
  rescue => e
    @logger.warn("Codex token refresh failed", email: account.email, error: e.message)
  end

  # Reads ~/.codex/auth.json and finds the matching codex ClaudeAccount by its
  # ChatGPT account_id (OAuth) or OPENAI_API_KEY (API-key). Returns nil when the
  # file is absent/unparseable or no account matches.
  def detect_filesystem_account
    return nil unless File.exist?(AUTH_JSON_PATH)

    fs = JSON.parse(File.read(AUTH_JSON_PATH))
    fs_account_id = fs.dig("tokens", "account_id")
    fs_api_key = fs["OPENAI_API_KEY"]

    pool = accounts.where.not(oauth_config: {}).to_a
    if fs_account_id.present?
      pool.find { |a| a.codex_account_id == fs_account_id }
    elsif fs_api_key.present?
      pool.find { |a| a.codex_api_key == fs_api_key }
    end
  rescue JSON::ParserError
    nil
  end

  # True when ~/.codex/auth.json already holds the given account's identity.
  def auth_file_matches?(account)
    return false unless File.exist?(AUTH_JSON_PATH)

    fs = JSON.parse(File.read(AUTH_JSON_PATH))
    if account.codex_api_key_account?
      fs["OPENAI_API_KEY"].present? && fs["OPENAI_API_KEY"] == account.codex_api_key
    else
      fs_account_id = fs.dig("tokens", "account_id")
      fs_account_id.present? && fs_account_id == account.codex_account_id
    end
  rescue JSON::ParserError
    false
  end

  # True when auth.json was modified more recently than the DB switch — used to
  # tell a manual `codex login` (filesystem wins) from a DB switch not yet
  # written to disk (DB wins).
  def filesystem_newer_than_db?(account)
    return false unless File.exist?(AUTH_JSON_PATH)

    fs_mtime = File.mtime(AUTH_JSON_PATH)
    db_switch_time = account.last_rotated_to_at
    return true if db_switch_time.nil?

    fs_mtime > db_switch_time
  rescue Errno::ENOENT
    false
  end
end
