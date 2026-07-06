# frozen_string_literal: true

# RuntimeAuthProvider — the contract for a coding-agent runtime's login-credential lifecycle.
#
# Zimmer drives agent CLIs (today: `claude`; forthcoming: `codex`, see #3766) that
# authenticate against their vendor without an API key by reading login
# credentials from a canonical filesystem location. Zimmer maintains a pool of
# accounts per runtime, rotates between them when quotas are hit, and keeps the
# active account's credentials fresh and written to disk before each spawn.
#
# Every runtime authenticates differently — different token endpoints, credential
# file layouts, and refresh cadences — so this class is the single seam through
# which the rest of the app talks to "the auth pool for runtime X". Call sites
# resolve the provider for a session's runtime via `RuntimeAuthProvider.for(...)`
# and never reference a concrete runtime's accounts or constants directly.
#
# This base class is the interface; `ClaudeAuthProvider` and `CodexAuthProvider`
# are the concrete implementations.
#
# == Required methods (must be implemented by subclasses) ==
#
# runtime -> String
#   The runtime identifier this provider authenticates (e.g. "claude_code").
#
# accounts -> ActiveRecord::Relation
#   The account pool scoped to this runtime.
#
# current_account -> account record, nil
#   The account currently active on the worker (its credentials are the ones on
#   disk). The DB is the source of truth.
#
# select_account_for(session) -> account record, nil
#   The account that should serve the given session — the current account if one
#   is active, otherwise the next available account in the pool.
#
# refresh!(account) -> Result
#   Refresh the account's access token via the runtime's token endpoint. Returns
#   a Result whose #ok? reports success; on failure, #error is :needs_reauth when
#   the credentials are permanently invalid or :transient when a retry may help.
#
# inject_for_session!(session, working_directory) -> account record, nil
#   Reconcile filesystem ↔ DB and write the active account's credentials to the
#   runtime's canonical filesystem location so the next CLI spawn authenticates
#   as that account. Called immediately before spawning. working_directory is
#   accepted for runtimes that write per-clone credentials; runtimes that write
#   to a fixed home-dir location (Claude) ignore it.
#
# rotation_interval -> ActiveSupport::Duration
#   How often the token-refresh dispatcher should sweep this runtime's pool. The
#   cron entry runs RefreshRuntimeAuthTokensJob, which fans out per registered
#   runtime; each runtime declares its own cadence here.
#
# == Optional hooks (sensible defaults provided here) ==
#
# recover_needs_reauth(account) -> Boolean
#   Attempt to recover an account stuck in needs_reauth (e.g. after manual
#   re-authentication). Returns true if recovered. Defaults to a no-op (false)
#   for runtimes whose CLI repairs its own credentials in place.
#
# == Dispatcher hooks (called by RefreshRuntimeAuthTokensJob on every provider) ==
#
# The token-refresh dispatcher sweeps every registered provider each tick and
# calls the hooks below before refreshing expiring tokens. They default to
# no-ops here so a provider only overrides the ones its runtime needs.
#
# reconcile_filesystem_identity! -> void
#   Adopt a manual filesystem identity switch (e.g. `claude /login`) into the DB
#   so the subsequent token sync targets the right account.
#
# sync_current_account_tokens! -> void
#   Sync filesystem tokens for the current account back to the DB. A runtime's
#   CLI may rotate the refresh token on disk, making the DB copy stale.
#
# needs_reauth_recovery_candidates -> Array<account>
#   Accounts stuck in needs_reauth that still hold a refresh token worth retrying
#   via #recover_needs_reauth.
#
# == Quota-rotation hook (called by ProcessLifecycleManager) ==
#
# rotate_for_quota!(triggered_by:) -> Hash
#   Rotate away from the current account after it hit a usage quota, activating
#   the next available account in the pool. Returns { success:, account: } on
#   success or { success: false, reason: } when no account is available. Defaults
#   to a no-op result for runtimes that don't pool quota-limited accounts.
class RuntimeAuthProvider
  # Outcome of a token refresh attempt.
  #   ok    - true when the refresh succeeded
  #   error - nil on success; :needs_reauth (permanent) or :transient on failure
  Result = Data.define(:ok, :error) do
    def ok? = ok
  end

  # Runtimes Zimmer can authenticate.
  RUNTIMES = %w[claude_code codex].freeze

  # Resolve the auth provider for a runtime identifier.
  #
  # @param runtime [String, Symbol, nil] runtime identifier. nil/blank defaults
  #   to Claude Code, since that is Zimmer's only runtime today and keeps every
  #   existing call site (which pass session.agent_runtime == "claude_code") on the
  #   unchanged Claude path.
  # @return [RuntimeAuthProvider]
  def self.for(runtime)
    case runtime&.to_s
    when nil, "", "claude", "claude_code"
      ClaudeAuthProvider.new
    when "codex"
      CodexAuthProvider.new
    else
      raise ArgumentError, "No auth provider registered for runtime #{runtime.inspect}"
    end
  end

  # All registered runtime providers, one instance each. Used by the token
  # refresh dispatcher to fan out across every runtime Zimmer authenticates.
  #
  # @return [Array<RuntimeAuthProvider>]
  def self.registered
    RUNTIMES.map { |runtime| self.for(runtime) }
  end

  def runtime
    raise NotImplementedError, "#{self.class} must implement #runtime"
  end

  def accounts
    raise NotImplementedError, "#{self.class} must implement #accounts"
  end

  def current_account
    raise NotImplementedError, "#{self.class} must implement #current_account"
  end

  def select_account_for(session)
    raise NotImplementedError, "#{self.class} must implement #select_account_for"
  end

  def refresh!(account)
    raise NotImplementedError, "#{self.class} must implement #refresh!"
  end

  def inject_for_session!(session, working_directory = nil)
    raise NotImplementedError, "#{self.class} must implement #inject_for_session!"
  end

  # Activate a specific, already-validated account: write its credentials to the
  # runtime's canonical filesystem location and mark it current in the DB. Drives
  # the manual switch and safe-delete paths in QuotasController so both runtimes
  # share one activation seam. Callers validate the account's credentials first
  # (e.g. via account.refresh_token!).
  #
  # @return [account] the activated account
  def activate!(account)
    raise NotImplementedError, "#{self.class} must implement #activate!"
  end

  def rotation_interval
    raise NotImplementedError, "#{self.class} must implement #rotation_interval"
  end

  # Optional: attempt to recover an account stuck in needs_reauth. Defaults to a
  # no-op for runtimes whose CLI repairs its own credentials in place.
  #
  # @return [Boolean] true if the account was recovered to a usable state
  def recover_needs_reauth(account)
    false
  end

  # Dispatcher hook: adopt a manual filesystem identity switch into the DB.
  # Defaults to a no-op for runtimes that don't support manual re-login.
  def reconcile_filesystem_identity!
    nil
  end

  # Dispatcher hook: sync filesystem tokens for the current account back to the
  # DB. Defaults to a no-op for runtimes whose CLI doesn't rotate tokens on disk.
  def sync_current_account_tokens!
    nil
  end

  # Dispatcher hook: accounts stuck in needs_reauth that are worth retrying via
  # #recover_needs_reauth. Defaults to none.
  #
  # @return [Array<account>]
  def needs_reauth_recovery_candidates
    []
  end

  # Quota-rotation hook: rotate away from the current account after it hit a
  # usage quota. Defaults to a no-op result for runtimes that don't pool
  # quota-limited accounts.
  #
  # @return [Hash] { success:, account: } or { success: false, reason: }
  def rotate_for_quota!(triggered_by: nil)
    { success: false, reason: "rotation_not_supported" }
  end
end
