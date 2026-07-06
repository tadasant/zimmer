# frozen_string_literal: true

# Manages rotation between Claude Code accounts when usage quotas are hit.
#
# All sessions on a worker share a single ~/.claude.json identity. When one
# account hits its quota, this service switches to the next available account
# and writes its credentials to ~/.claude.json so subsequent CLI spawns use
# the new identity.
#
# Usage:
#   service = AccountRotationService.new
#   result = service.rotate!
#   # => { success: true, account: <ClaudeAccount> }
#   # => { success: false, reason: "no_available_accounts" }
class AccountRotationService
  # The canonical credential file paths live in ClaudeAuthProvider, the single
  # source of truth for Claude's auth lifecycle.

  def initialize
    @logger = StructuredLogger.new({ service: "AccountRotationService" })
  end

  # Rotate away from the current account to the next available one.
  # Marks the current account as quota_exceeded and takes quota snapshots.
  #
  # @param reason [String] why the rotation happened (e.g., "quota_exceeded")
  # @param triggered_by [String] what triggered the rotation (e.g., "session:123")
  # @return [Hash] { success: true, account: ClaudeAccount } or { success: false, reason: String }
  def rotate!(reason: "quota_exceeded", triggered_by: nil)
    current = ClaudeAccount.current_account

    if current
      # Sync filesystem tokens back to DB before rotating away.
      # Claude Code CLI may have refreshed tokens that we need to preserve.
      sync_current_tokens(current)

      # Take a snapshot of the outgoing account before switching
      take_snapshot(current, trigger: "rotation")
      current.mark_quota_exceeded!
      @logger.info("Marked account as quota_exceeded", email: current.email)
    end

    result = activate_next_account(exclude_ids: [ current&.id ].compact)

    # Log the rotation event (non-bang to avoid disrupting the rotation on logging failure)
    if result[:success]
      event = AccountRotationEvent.create(
        rotated_from: current,
        rotated_to: result[:account],
        reason: reason,
        source: "automatic",
        triggered_by: triggered_by
      )
      @logger.warn("Failed to log rotation event", errors: event.errors.full_messages) unless event.persisted?
    end

    result
  end

  # Adopt the filesystem identity into the DB when the CLI was manually
  # switched to a different known active account (typically via `claude
  # /login` on the worker). Returns the adopted account, or nil if no
  # adoption occurred. Safe to call frequently from any code path that
  # wants the DB to track filesystem changes — quotas page render,
  # token refresh cron, session start.
  #
  # Skips adoption when:
  #   - no DB-current account exists (caller must bootstrap)
  #   - filesystem matches DB (already in sync)
  #   - filesystem identity has no DB record (call sync_from_filesystem! to bootstrap)
  #   - filesystem identity is inactive or needs_reauth
  #   - DB switch is newer than the filesystem config (web UI switch
  #     hasn't been written to disk yet — caller should write_config!)
  def reconcile_with_filesystem!
    current = ClaudeAccount.current_account
    return nil unless current
    return nil if config_file_matches?(current)

    # Two gates, both required:
    #
    #   1. credentials_changed_externally? — the SHARED credentials file was
    #      written by something other than AO since our last marker stamp. This
    #      timestamp comparison is on the shared bind mount, so it is identical on
    #      the web and worker containers — it cannot be fooled by a stale,
    #      container-local ~/.claude.json (the divergence that previously let the
    #      web container "adopt" an identity the worker never switched to).
    #
    #   2. filesystem_newer_than_db? — that external write is more recent than the
    #      DB-current account's switch. Preserves DB-wins semantics: a web-UI
    #      switch that hasn't been written to disk yet beats an older filesystem
    #      state, so we don't revert it.
    return nil unless credentials_changed_externally?
    return nil unless filesystem_newer_than_db?(current)

    fs_account = detect_filesystem_account
    return nil unless fs_account
    return nil if fs_account.id == current.id
    return nil unless fs_account.active? && fs_account.has_valid_config?

    @logger.info("CLI manually switched to different account, adopting filesystem identity",
      db_current: current.email, fs_account: fs_account.email)
    fs_account.mark_current!
    # Stamp the marker to the adopted owner BEFORE syncing, so the token-capture
    # gate (which trusts the marker) recognizes the freshly-logged-in account.
    ClaudeAccount.write_credentials_owner_marker!(fs_account.email)
    fs_account.sync_tokens_from_filesystem!
    fs_account
  end

  # Ensure there's an active account configured. Called on session start.
  # If no account is current, picks the first available and writes its config.
  # Also refreshes expired tokens on the current account to prevent 401 errors.
  #
  # When the filesystem identity doesn't match the DB-current account, this
  # method checks whether the CLI was manually switched to a different known
  # account. If so, the DB adopts the filesystem account as current (staying
  # in sync with manual overrides). Otherwise, it writes the DB-current
  # account's config to disk.
  def ensure_active_account!
    current = ClaudeAccount.current_account

    if current&.active? && current&.has_valid_config?
      if config_file_matches?(current)
        # The container-local identity file agrees this is the current account,
        # so it owns the shared credentials. Bootstrap the shared owner marker if
        # it's missing (the post-deploy transition window) so the marker-gated
        # sync paths recognize ownership. Only stamps when ABSENT — never clobbers
        # an existing marker, so a rotation on the other container can't be raced.
        bootstrap_owner_marker(current)
        # Filesystem matches DB — sync tokens in case CLI refreshed them
        sync_current_tokens(current)
      else
        # Filesystem doesn't match DB — try to adopt the filesystem identity
        # if the CLI was manually switched to a different known active account.
        adopted = reconcile_with_filesystem!
        if adopted
          current = adopted
        else
          # DB switch is more recent, unknown identity, or inactive account — write DB-current to disk.
          # Capture the filesystem identity's CLI-rotated tokens to its DB row first;
          # otherwise write_config! clobbers credentials the CLI may have rotated and
          # leaves that account bricked the next time it is selected.
          capture_outgoing_filesystem_tokens(except: current)
          @logger.info("Filesystem config mismatch, syncing DB-current account to disk", email: current.email)
          write_config!(current)
        end
      end

      # Refresh if tokens are expired or expiring soon
      if current.token_expired? || current.token_expiring_soon?
        @logger.info("Refreshing expired/expiring tokens for current account", email: current.email)
        if current.refresh_token!
          write_config!(current)
        else
          @logger.warn("Token refresh failed for current account", email: current.email)
        end
      end

      return current
    end

    # Pick the first available account
    account = ClaudeAccount.available.for_runtime(ClaudeAuthProvider::RUNTIME).first

    unless account
      # No current and no available. The usual cause is DB records were
      # added via `claude_accounts:add` but `capture_tokens` was skipped,
      # so every account has an empty oauth_config. If the filesystem
      # holds freshly-minted tokens from a recent `claude /login`, adopt
      # them into the matching DB record before giving up.
      bootstrapped = ClaudeAccount.sync_from_filesystem!
      if bootstrapped&.has_valid_config?
        @logger.info("Bootstrapped account from filesystem", email: bootstrapped.email)
        account = ClaudeAccount.available.for_runtime(ClaudeAuthProvider::RUNTIME).first
      end
      return nil unless account
    end

    # Refresh if needed before writing config
    ensure_fresh_tokens!(account)

    # Write config to filesystem BEFORE marking current in the DB
    write_config!(account)
    account.mark_current!
    @logger.info("Set initial active account", email: account.email)
    account
  end

  # Activate a validated account: write its config to the filesystem, mark
  # it as current in the DB, and take a quota snapshot. Used by both the
  # automatic rotation path (via #activate_next_account) and the manual
  # switch path (via QuotasController#switch_account) so the filesystem and
  # DB stay in sync regardless of which entry point is used.
  #
  # Callers are responsible for validating the account's tokens before
  # calling this (e.g., via account.refresh_token!). The order — write
  # config to the filesystem BEFORE marking current in the DB — prevents a
  # race where concurrent current_account calls see a DB-current account
  # whose credentials aren't on the filesystem yet, triggering
  # reconciliation that can corrupt token identity.
  def activate!(account, snapshot_trigger:)
    # Capture the outgoing identity's CLI-rotated tokens before write_config!
    # overwrites the credentials file. Without this, every switch (manual or
    # automatic) silently drops any refresh_token rotation the CLI performed
    # while the outgoing account was current — leaving the outgoing account's
    # DB copy stale and bricking it the next time anyone tries to use it.
    # Rotation's #rotate! also calls sync_current_tokens beforehand, but this
    # in-method capture is the only thing protecting the manual switch path.
    capture_outgoing_filesystem_tokens(except: account)

    write_config!(account)
    account.mark_current!
    take_snapshot(account, trigger: snapshot_trigger)
  end

  # Write an account's OAuth config to ~/.claude.json (identity; container-local)
  # and its credentials to ~/.claude/.credentials.json (tokens; shared).
  #
  # The credentials write is delegated to the model so the completeness guard and
  # the shared owner-marker stamp are applied in exactly one place — every disk
  # write of credentials goes through ClaudeAccount#write_credentials_to_filesystem!.
  def write_config!(account)
    # Write ~/.claude.json (contains oauthAccount field)
    claude_json = account.oauth_config.fetch("claude_json", {})
    if claude_json.present?
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.pretty_generate(claude_json))
      @logger.info("Wrote ~/.claude.json", email: account.email)
    end

    # Write ~/.claude/.credentials.json + the owner marker (model enforces the
    # accessToken+refreshToken completeness guard and refuses incomplete sets).
    if account.write_credentials_to_filesystem!
      @logger.info("Wrote ~/.claude/.credentials.json", email: account.email)
    else
      @logger.warn("Did not write credentials to filesystem", email: account.email)
    end
  end

  # Parse quota reset time from the error message.
  # Handles formats like:
  #   "resets 5pm (UTC)"
  #   "resets 11pm (UTC)"
  #   "resets Mar 6, 3am (UTC)"
  #
  # @param error_message [String] the quota error message
  # @return [Time, nil] parsed reset time in UTC, or nil if unparsable
  def self.parse_quota_reset_time(error_message)
    return nil if error_message.blank?

    # Match "resets <time> (UTC)" patterns
    match = error_message.match(/resets\s+(.+?)\s*\(UTC\)/i)
    return nil unless match

    time_str = match[1].strip

    begin
      # Try parsing with month+day: "Mar 6, 3am"
      if time_str.match?(/[A-Za-z]+\s+\d+/)
        Time.parse("#{time_str} UTC")
      else
        # Simple time: "5pm", "11pm"
        today = Time.current.utc.to_date
        Time.parse("#{today} #{time_str} UTC")
      end
    rescue ArgumentError
      nil
    end
  end

  private

  # Find and activate the next available account, validating tokens by
  # probing Anthropic's OAuth endpoint before writing them to the filesystem.
  # Skips accounts whose tokens fail validation and tries the next one.
  # Does NOT mark failed accounts as needs_reauth — that decision belongs to
  # refresh_token! (for permanent OAuth errors) and the background refresh job
  # (after retry exhaustion). Marking needs_reauth here previously caused a
  # cascade that bricked the entire account pool on a single bad rotation.
  def activate_next_account(exclude_ids:)
    next_account = ClaudeAccount.available.for_runtime(ClaudeAuthProvider::RUNTIME).where.not(id: exclude_ids).first

    unless next_account
      @logger.warn("No available accounts for rotation")
      return { success: false, reason: "no_available_accounts" }
    end

    # Validate the account's tokens by calling refresh_token! before writing
    # them to the filesystem. The previous date-only check (token_expired?
    # / token_expiring_soon?) lets through bogus credentials with sentinel
    # expiresAt values (e.g., 9999999999999 from accidentally-loaded test
    # fixture data) or unexpired-but-revoked tokens. Either case writes
    # garbage to ~/.claude/.credentials.json and 401s every subsequent
    # session. Probing the OAuth endpoint catches both.
    unless next_account.can_refresh_token?
      @logger.warn("Account has no refresh token, skipping during rotation", email: next_account.email)
      return activate_next_account(exclude_ids: exclude_ids + [ next_account.id ])
    end

    @logger.info("Validating tokens before activation", email: next_account.email)
    unless next_account.refresh_token!
      @logger.warn("Token validation failed during rotation, skipping account", email: next_account.email)
      return activate_next_account(exclude_ids: exclude_ids + [ next_account.id ])
    end

    activate!(next_account, snapshot_trigger: "rotation")

    @logger.info("Rotated to account", email: next_account.email, priority: next_account.priority)
    { success: true, account: next_account }
  end

  # Write the shared owner marker for an account only if no marker exists yet.
  # This converges the marker into existence after a deploy without ever
  # overwriting a marker another container's write may have just set.
  def bootstrap_owner_marker(account)
    return if ClaudeAccount.credentials_owner_email.present?

    ClaudeAccount.write_credentials_owner_marker!(account.email)
    @logger.info("Bootstrapped shared credentials owner marker", email: account.email)
  end

  # Sync filesystem tokens back to DB for the current account
  def sync_current_tokens(account)
    account.sync_tokens_from_filesystem!
    @logger.info("Synced filesystem tokens to DB", email: account.email)
  rescue => e
    @logger.warn("Failed to sync filesystem tokens", email: account.email, error: e.message)
  end

  # Capture the CLI-rotated tokens belonging to whoever currently owns the
  # filesystem credentials, so they aren't lost when write_config! overwrites
  # the file with a different account's config. Looks up the owner by the
  # ~/.claude.json identity rather than DB is_current?, because the two can
  # disagree (manual `claude /login`, cross-container switches). Skips the
  # capture entirely when the filesystem identity matches the incoming
  # account or when there is no filesystem identity to capture from.
  def capture_outgoing_filesystem_tokens(except:)
    # The outgoing owner is whoever the SHARED marker names — not whatever the
    # container-local ~/.claude.json says. Using the marker is what keeps a switch
    # on one container from mis-attributing the other container's view of the
    # shared credentials. sync_tokens_from_filesystem! re-checks the marker, so
    # this is defense in depth.
    owner_email = ClaudeAccount.credentials_owner_email
    return if owner_email.blank?
    return if except && owner_email == except.email

    fs_account = ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).find_by(email: owner_email)
    return if fs_account.nil?

    fs_account.sync_tokens_from_filesystem!
    @logger.info("Captured outgoing filesystem tokens to DB", email: fs_account.email)
  rescue => e
    @logger.warn("Failed to capture outgoing filesystem tokens", error: e.message)
  end

  # True when the shared ~/.claude/.credentials.json was modified more recently
  # than AO last stamped the owner marker — i.e., something other than AO (the
  # Claude CLI rotating tokens, or an operator's manual `claude /login`) wrote the
  # credentials since our last write. Both files live in the shared bind mount, so
  # this comparison yields the same answer on the web and worker containers.
  #
  # Conservative default: with no marker yet (the post-deploy transition window)
  # we report false, so identity adoption stays off until AO has stamped the
  # marker at least once.
  def credentials_changed_externally?
    marker = ClaudeAuthProvider.credentials_owner_path
    creds = ClaudeAuthProvider::CREDENTIALS_JSON_PATH
    return false unless File.exist?(marker) && File.exist?(creds)

    File.mtime(creds) > File.mtime(marker)
  rescue Errno::ENOENT
    false
  end

  # Refresh tokens if expired, without failing the overall operation
  def ensure_fresh_tokens!(account)
    return unless account.token_expired? || account.token_expiring_soon?
    return unless account.can_refresh_token?

    @logger.info("Refreshing expired/expiring tokens", email: account.email)
    account.refresh_token!
  rescue => e
    @logger.warn("Token refresh failed", email: account.email, error: e.message)
  end

  # Take a quota snapshot for an account using its DB-stored OAuth token
  def take_snapshot(account, trigger:)
    token = account.oauth_config&.dig("credentials_json", "claudeAiOauth", "accessToken")
    return unless token.present?

    result = QuotaCheckService.check_with_token(token)
    return unless result.success?

    QuotaSnapshotService.save_snapshot(account, result, trigger: trigger)
  rescue => e
    @logger.error("Failed to take quota snapshot", email: account.email, error: e.message)
  end

  # Returns true if the filesystem config file was modified more recently
  # than the DB-current account was switched. Used to distinguish between
  # a manual `claude /login` (filesystem wins) and a web UI switch that
  # hasn't been written to disk yet (DB wins).
  def filesystem_newer_than_db?(current_account)
    return false unless File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)

    fs_mtime = File.mtime(ClaudeAuthProvider::CLAUDE_JSON_PATH)
    db_switch_time = current_account.last_rotated_to_at

    # If the DB has no record of when the switch happened, trust filesystem
    return true if db_switch_time.nil?

    fs_mtime > db_switch_time
  rescue Errno::ENOENT
    false
  end

  # Reads the filesystem ~/.claude.json and looks up the corresponding
  # ClaudeAccount by oauthAccount identity. Returns nil if the file
  # doesn't exist, can't be parsed, or no matching account is found.
  def detect_filesystem_account
    return nil unless File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)

    fs_config = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    fs_email = extract_oauth_email(fs_config["oauthAccount"])
    return nil if fs_email.blank?

    ClaudeAccount.for_runtime(ClaudeAuthProvider::RUNTIME).find_by(email: fs_email)
  rescue JSON::ParserError, Errno::ENOENT
    nil
  end

  # Check if the current ~/.claude.json matches the account's stored config
  def config_file_matches?(account)
    return false unless File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)

    current_config = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    stored_config = account.oauth_config.fetch("claude_json", {})
    return true if stored_config.blank? # Can't verify, assume ok

    extract_oauth_email(current_config["oauthAccount"]) == extract_oauth_email(stored_config["oauthAccount"])
  rescue JSON::ParserError, Errno::ENOENT
    false
  end

  # Extracts the email from an oauthAccount value, which can be a plain string
  # (legacy CLI format) or a Hash with "emailAddress" (current CLI format).
  def extract_oauth_email(oauth_account)
    return nil if oauth_account.blank?
    oauth_account.is_a?(Hash) ? oauth_account["emailAddress"] : oauth_account
  end
end
