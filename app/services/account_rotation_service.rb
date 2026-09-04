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

  # How recently another session must have rotated onto an account for a caller
  # to ride that rotation instead of performing its own. Sized to a stampede —
  # the racers arrive within seconds of each other — and deliberately far below
  # the time a session would spend actually working on the new account.
  COLLAPSE_WINDOW = 60.seconds

  # The rotation reasons that are themselves evidence the outgoing account hit a
  # quota wall — the caller watched the runtime refuse the request for quota, and
  # that observation stands even when the account cannot be probed afterwards.
  #
  # Everything else is a rotation for some other cause, and says nothing about
  # the outgoing account's quota. A reason this does not recognise is treated as
  # one of those: over-labelling is the failure mode this list exists to prevent,
  # so a new reason has to opt in rather than be assumed in.
  QUOTA_ROTATION_REASONS = %w[quota_exceeded].freeze

  def initialize
    @logger = StructuredLogger.new({ service: "AccountRotationService" })
  end

  # Rotate away from the current account to the next available one.
  # Marks the current account as quota_exceeded and takes quota snapshots.
  #
  # Serialized pool-wide. Every session that hits a quota wall calls this, so a
  # stampede used to have N sessions read the same `current`, pick the same
  # successor, and each call `refresh_token!` on it — and Anthropic's refresh
  # tokens are single-use, so the losers got `invalid_grant` and condemned a
  # healthy account to needs_reauth. That is what drained the pool (#242).
  #
  # The lock alone only serializes the stampede; it does not collapse it. Racers
  # would still rotate in sequence, one account burned each. So a caller passes
  # the identity it was actually running as, and a racer that finds the pool has
  # already moved off that identity returns the new account instead of rotating
  # again — which is the same "someone else already fixed this" test
  # AuthRecoveryCoordinator makes.
  #
  # @param reason [String] why the rotation happened (e.g., "quota_exceeded")
  # @param triggered_by [String] what triggered the rotation (e.g., "session:123")
  # @param expected_current_email [String, nil] the identity the caller was running
  #   as. When the pool has already moved off it, the caller's complaint is stale.
  # @return [Hash] { success: true, account: ClaudeAccount } or { success: false, reason: String }
  def rotate!(reason: "quota_exceeded", triggered_by: nil, expected_current_email: nil)
    result = ClaudeAccount.with_pool_lock(ClaudeAuthProvider::RUNTIME) do
      [ rotate_under_lock(reason, triggered_by, expected_current_email) ]
    end

    return result.first if result

    @logger.warn("Could not acquire the account pool lock — another rotation is still running")
    { success: false, reason: "rotation_in_flight" }
  end

  # A rotation this caller can ride instead of performing its own.
  #
  # Two conditions, and the second one matters more than it looks. "The pool is
  # not on the account I expected" is NOT sufficient: a caller's recorded
  # identity goes stale whenever the pool moves without telling it (another
  # session's rotation, an operator's manual switch), so a long-running session
  # that has since been happily using account B would pass expected=A, see
  # current=B, and collapse — getting re-spawned straight back onto the account
  # whose quota it just hit.
  #
  # So the rotation must also be RECENT. A stampede is N sessions arriving within
  # seconds of each other; a pool that moved onto this account minutes ago is one
  # the caller has been living with, and its complaint is about that account.
  def collapse_onto?(current, expected_current_email)
    return false if expected_current_email.blank?
    return false if current.nil?
    return false if current.email == expected_current_email

    rotated_at = current.last_rotated_to_at
    rotated_at.present? && rotated_at > COLLAPSE_WINDOW.ago
  end
  private :collapse_onto?

  # The body of #rotate!, run with the pool lock held.
  private def rotate_under_lock(reason, triggered_by, expected_current_email)
    # Re-read under the lock: a racer that queued behind another rotation must
    # see the pool as it is now, not as it was when it decided to rotate.
    current = ClaudeAccount.current_account

    if collapse_onto?(current, expected_current_email)
      @logger.info("Rotation already performed by another session, collapsing",
        expected: expected_current_email, current: current.email)
      return { success: true, account: current, collapsed: true }
    end

    if current
      # Sync filesystem tokens back to DB before rotating away.
      # Claude Code CLI may have refreshed tokens that we need to preserve.
      sync_current_tokens(current)

      # Take a snapshot of the outgoing account before switching
      snapshot = take_snapshot(current, trigger: "rotation")

      mark_outgoing!(current, reason, snapshot)
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

  # Record what rotating away from `current` proves about it.
  #
  # A rotation is not, by itself, a statement about the outgoing account's
  # quota. `auth_recovery` rotates because the runtime said "Not logged in",
  # which says nothing about quota — and since `status` is what
  # `ClaudeAccount.available` reads, a `quota_exceeded` label with no reading
  # behind it does not merely mislabel the account, it removes it from the pool.
  # One blanked credential is then enough to empty the whole pool in seconds; see
  # [A rotation is not evidence about quota] in docs/auth/harness.md.
  #
  # So label on evidence, in this order:
  #
  #   * needs_reauth, or already quota_exceeded — the caller (or this account's
  #     own reading, via QuotaSnapshotService) has already diagnosed it. Leave it
  #     alone: the two statuses drive different recoveries, and marking twice
  #     would count one wall as two quota hits on the page.
  #   * the reading this rotation just took says the account cannot serve — the
  #     strongest evidence available, and it condemns the account whatever the
  #     rotation was for. Asked as `!windows_clear?`, the SAME predicate
  #     ClaudeAccount#effective_status renders and QuotaResetCheckerJob restores
  #     on, so a label this writes is one the rest of the app will honour. The
  #     narrower `five_hour_window_spent?` would write labels `windows_clear?`
  #     immediately overrules — a mark nothing acts on and every spawn path
  #     still refuses.
  #   * the caller rotated FOR a quota wall — it watched the runtime refuse the
  #     request, which is evidence even when the probe could not be taken.
  #
  # Anything else leaves the account active, because nothing observed says
  # otherwise.
  #
  # @param current [ClaudeAccount] the account being rotated away from
  # @param reason [String] why the caller rotated; see QUOTA_ROTATION_REASONS
  # @param snapshot [ClaudeAccountQuotaSnapshot, nil] the reading #take_snapshot
  #   just took, or nil when the account could not be probed
  def mark_outgoing!(current, reason, snapshot)
    if current.needs_reauth?
      @logger.info("Rotating away from account already marked needs_reauth", email: current.email)
      return
    end

    if current.quota_exceeded?
      @logger.info("Account was already marked quota_exceeded by its own quota reading", email: current.email)
      return
    end

    reading_condemns = snapshot.present? && !snapshot.windows_clear?

    unless reading_condemns || QUOTA_ROTATION_REASONS.include?(reason)
      @logger.info("Rotated away without quota evidence — leaving the account active",
        email: current.email, reason: reason, probed: snapshot.present?)
      return
    end

    current.mark_quota_exceeded!
    @logger.info("Marked account as quota_exceeded",
      email: current.email, reason: reason, reading_condemns: reading_condemns)
  end
  private :mark_outgoing!

  # Ensure there's an active account configured. Called on session start.
  # If no account is current, picks the first available and writes its config.
  # Also refreshes expired tokens on the current account to prevent 401 errors.
  #
  # Under session-scoped credentials the filesystem is not a party to any of
  # this — see #ensure_active_account_from_db!, which is the whole method.
  #
  # With the setting off, the DB-current account's config is written to disk
  # whenever the on-disk identity does not already agree with it. The DB wins:
  # there is no longer a branch that adopts an identity off the filesystem,
  # because a file the CLI and Zimmer both write is not evidence of who the pool
  # should be running as, and acting on it is what let a container replacement
  # silently change which account production ran under (#618, addendum B).
  def ensure_active_account!
    return ensure_active_account_from_db! if session_scoped_credentials?

    current = ClaudeAccount.current_account

    if current&.active? && current&.has_valid_config?
      if config_file_matches?(current) || adopt_own_filesystem_identity(current)
        # The container-local identity file agrees this is the current account,
        # so it owns the shared credentials. Bootstrap the shared owner marker if
        # it's missing (the post-deploy transition window) so the marker-gated
        # sync paths recognize ownership. Only stamps when ABSENT — never clobbers
        # an existing marker, so a rotation on the other container can't be raced.
        bootstrap_owner_marker(current)
        # Filesystem matches DB — sync tokens in case CLI refreshed them
        sync_current_tokens(current)
      else
        # The on-disk identity does not agree with the DB-current account, so the
        # DB is what gets written. Capture the filesystem owner's CLI-rotated
        # tokens to its own DB row first; otherwise write_config! clobbers
        # credentials the CLI may have rotated and leaves that account bricked
        # the next time it is selected.
        capture_outgoing_filesystem_tokens(except: current)
        @logger.info("Filesystem config mismatch, syncing DB-current account to disk", email: current.email)
        write_config!(current)
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

    # Pick the first available account whose credentials we can prove work
    account = first_usable_available_account

    unless account
      # No current account and nothing usable. There is no filesystem fallback:
      # adopting whatever tokens happen to be on disk is the two-sources-of-truth
      # problem this system is being taken apart to remove, and the answer is the
      # Authenticate button on /inference, which writes the DB and needs no shell.
      @logger.warn("No usable Claude account in the pool — authenticate one from /inference")
      return nil
    end

    # Capture whoever owns the credentials on disk before overwriting them. This
    # path is reached whenever the current account stops being `active` — which a
    # quota reading can do without any rotation running — and without the capture
    # it drops any refresh token the CLI rotated for that account, bricking it the
    # next time the pool selects it. Same guarantee #activate! gives the other
    # activation paths.
    capture_outgoing_filesystem_tokens(except: account)

    # Write config to filesystem BEFORE marking current in the DB
    write_config!(account)
    account.mark_current!
    @logger.info("Set initial active account", email: account.email)
    account
  end

  # #ensure_active_account! under session-scoped credentials: the same job with
  # the filesystem removed from it entirely.
  #
  # There is no config file to compare against, no identity to adopt, and nothing
  # to write — the session gets its token from this account's DB row via
  # CLAUDE_CODE_OAUTH_TOKEN. What is left is the part that was always the real
  # work: make sure a usable account is current and its access token is fresh.
  #
  # @return [ClaudeAccount, nil]
  def ensure_active_account_from_db!
    current = ClaudeAccount.current_account

    # `claude_access_token`, not just `has_valid_config?`: the token IS what the
    # session is handed, so a row carrying only a stored identity is not a usable
    # current account here even though the hash is non-empty. Keeping it current
    # would spawn token-less sessions while /health called the same row corrupt.
    if current&.active? && current&.claude_access_token.present?
      if current.token_expired? || current.token_expiring_soon?
        @logger.info("Refreshing expired/expiring tokens for current account", email: current.email)
        @logger.warn("Token refresh failed for current account", email: current.email) unless current.refresh_token!
        current.reload
      end
      return current
    end

    account = first_usable_available_account
    unless account
      @logger.warn("No usable Claude account in the pool — authenticate one from /inference")
      return nil
    end

    account.mark_current!
    @logger.info("Set initial active account", email: account.email)
    account
  end

  # Activate a validated account: write its config to the filesystem, mark
  # it as current in the DB, and take a quota snapshot. Used by both the
  # automatic rotation path (via #activate_next_account) and the manual
  # switch path (via InferenceController#switch_account) so the filesystem and
  # DB stay in sync regardless of which entry point is used.
  #
  # Callers are responsible for validating the account's tokens before
  # calling this (e.g., via account.refresh_token!). The order — write
  # config to the filesystem BEFORE marking current in the DB — prevents a
  # race where concurrent current_account calls see a DB-current account
  # whose credentials aren't on the filesystem yet, triggering
  # reconciliation that can corrupt token identity.
  def activate!(account, snapshot_trigger:)
    # Under session-scoped credentials there is nothing on the filesystem to
    # capture or overwrite: a switch is a DB write and a snapshot, and every
    # session spawned after it reads the new account's token out of the row.
    # This is what collapses "Switch" from a two-store reconciliation into one
    # UPDATE — see issue #618.
    unless session_scoped_credentials?
      # Capture the outgoing identity's CLI-rotated tokens before write_config!
      # overwrites the credentials file. Without this, every switch (manual or
      # automatic) silently drops any refresh_token rotation the CLI performed
      # while the outgoing account was current — leaving the outgoing account's
      # DB copy stale and bricking it the next time anyone tries to use it.
      # Rotation's #rotate! also calls sync_current_tokens beforehand, but this
      # in-method capture is the only thing protecting the manual switch path.
      capture_outgoing_filesystem_tokens(except: account)
      write_config!(account)
    end

    account.mark_current!
    take_snapshot(account, trigger: snapshot_trigger)
  end

  # Write an account's OAuth config to ~/.claude.json (identity; container-local)
  # and its credentials to ~/.claude/.credentials.json (tokens; shared).
  #
  # The credentials write is delegated to the model so the completeness guard and
  # the shared owner-marker stamp are applied in exactly one place — every disk
  # write of credentials goes through ClaudeAccount#write_credentials_to_filesystem!.
  #
  # @param force [Boolean] passed through to the credential write: skip the
  #   backwards-write guard because the caller holds a credential newer than
  #   anything on disk by construction (an interactive login).
  def write_config!(account, force: false)
    # Belt and braces. Every caller is already gated, but this is the one method
    # in the codebase that can put a subscription refresh token on the shared
    # filesystem, so it refuses outright when the filesystem is not supposed to
    # hold one. A stray call is a bug to see in the log, not a credential to
    # write.
    if session_scoped_credentials?
      @logger.info("Skipping the filesystem credential write: session-scoped credentials are on", email: account.email)
      return
    end

    # Write ~/.claude.json (contains oauthAccount field)
    claude_json = account.oauth_config.fetch("claude_json", {})
    if claude_json.present?
      File.write(ClaudeAuthProvider::CLAUDE_JSON_PATH, JSON.pretty_generate(claude_json))
      @logger.info("Wrote ~/.claude.json", email: account.email)
    end

    # Write ~/.claude/.credentials.json + the owner marker (model enforces the
    # accessToken+refreshToken completeness guard and refuses incomplete sets).
    if account.write_credentials_to_filesystem!(force: force)
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

    # An account whose latest reading says its weekly allowance is spent cannot
    # serve the session we are rotating for. QuotaSnapshotService marks such an
    # account as each reading lands, so `available` normally excludes it already;
    # this catches the account whose evidence predates that marking, and marks it
    # so the pool stops offering it until QuotaResetCheckerJob restores it (#248).
    if quota_capped?(next_account)
      @logger.warn("Account's 7-day window is spent, skipping during rotation", email: next_account.email)
      next_account.mark_quota_exceeded!
      return activate_next_account(exclude_ids: exclude_ids + [ next_account.id ])
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

    # The snapshot activate! just took is a live reading, and it may be the first
    # evidence anyone has that this account's week is gone — in which case it has
    # already been marked. Handing the session an account the pool declared
    # unusable one line earlier would waste the rotation; move on to the next.
    unless next_account.reload.active?
      @logger.warn("Incoming account's fresh quota reading condemned it, rotating on",
        email: next_account.email, status: next_account.status)
      return activate_next_account(exclude_ids: exclude_ids + [ next_account.id ])
    end

    @logger.info("Rotated to account", email: next_account.email, priority: next_account.priority)
    { success: true, account: next_account }
  end

  # The first available account we can prove a session could actually use, or nil
  # when the pool has none.
  #
  # Bootstrap is the path that picks an identity when nothing is current, and it
  # validates like the other three (rotation, manual switch, filesystem adoption)
  # rather than taking `available.first` on faith. #ensure_fresh_tokens! swallows
  # its own failure by design, so an unvalidated pick let an account with a dead
  # refresh token become current and every session on the instance fail to
  # authenticate until a human intervened (#239).
  def first_usable_available_account
    ClaudeAccount.available.for_runtime(ClaudeAuthProvider::RUNTIME).find do |account|
      if quota_capped?(account)
        @logger.warn("Account's 7-day window is spent, skipping during bootstrap", email: account.email)
        account.mark_quota_exceeded!
        next false
      end

      usable_candidate?(account)
    end
  end

  # Probe one candidate and decide whether a session can be handed to it.
  #
  # The probe is QuotaCheckService's rather than refresh_token!'s precisely
  # because this runs over candidates we may not end up using: a refresh spends a
  # SINGLE-USE token, and spending one per candidate is how a healthy pool drains
  # itself (#242). Reading the rate-limit headers off a one-token request costs
  # nothing and cannot invalidate anything — so a healthy candidate is never
  # refreshed here, and only a candidate Anthropic actually refused is, since a
  # stale access token is the one refusal a refresh can fix.
  #
  # The reading is not thrown away. A successful probe carries this account's live
  # quota state, which is exactly the evidence rotation lacks for an account that
  # has never been current (#248), so it is recorded — and recording it is what
  # marks the account when its weekly window turns out to be spent.
  #
  # A probe that never reached Anthropic is not a verdict on the credential, and
  # the candidate is promoted unvalidated. Reading a provider outage as "every
  # account is dead" would park every session on the instance at once.
  def usable_candidate?(account)
    result = QuotaCheckService.check_with_token(account.claude_access_token)

    if !result.success? && !result.unreachable? && account.can_refresh_token?
      @logger.info("Candidate's token was refused, refreshing before deciding", email: account.email)
      account.refresh_token!
      account.reload
      result = QuotaCheckService.check_with_token(account.claude_access_token)
    end

    if result.success?
      snapshot = QuotaSnapshotService.save_snapshot(account, result, trigger: "bootstrap")
      return true unless snapshot.seven_day_window_spent?

      @logger.warn("Candidate's live reading shows its 7-day window is spent, skipping during bootstrap",
        email: account.email)
      return false
    end

    if result.unreachable?
      @logger.warn("Could not reach Anthropic to validate the candidate, promoting it unvalidated",
        email: account.email, error: result.error_message)
      return true
    end

    @logger.warn("Candidate's tokens were rejected by Anthropic, skipping during bootstrap",
      email: account.email, error: result.error_message)
    false
  end

  # True when the account's most recent quota reading says its weekly allowance is
  # gone. No snapshot means no evidence, which is not the same as bad evidence —
  # an account nobody has probed yet stays eligible.
  def quota_capped?(account)
    snapshot = account.latest_snapshot
    !snapshot.nil? && snapshot.seven_day_window_spent?
  end

  # Adopt the on-disk ~/.claude.json identity into the account's stored config
  # when the file already names this account, and report whether that happened.
  #
  # This is the converge step #config_file_matches? needs now that it fails closed
  # (#61): an account holding credentials but no stored identity — a fresh install,
  # or a row bootstrapped from credentials alone — can never satisfy the check, so
  # without this every session start would take the mismatch branch, rewrite the
  # filesystem, and arrive at the same unverifiable state next time. Adopting the
  # identity that is already on disk makes the check answerable from then on.
  def adopt_own_filesystem_identity(account)
    return false unless account.backfill_identity_from_filesystem!

    @logger.info("Adopted the on-disk identity into the stored config", email: account.email)
    true
  end

  # Write the shared owner marker for an account only if no marker exists yet.
  # This converges the marker into existence after a deploy without ever
  # overwriting a marker another container's write may have just set.
  def bootstrap_owner_marker(account)
    return if ClaudeAccount.credentials_owner_email.present?

    ClaudeAccount.write_credentials_owner_marker!(account.email)
    @logger.info("Bootstrapped shared credentials owner marker", email: account.email)
  end

  # Sync filesystem tokens back to DB for the current account. A no-op under
  # session-scoped credentials: no session writes the shared file, so there is
  # never anything on it to adopt.
  def sync_current_tokens(account)
    return if session_scoped_credentials?

    account.sync_tokens_from_filesystem!
    @logger.info("Synced filesystem tokens to DB", email: account.email)
  rescue => e
    @logger.warn("Failed to sync filesystem tokens", email: account.email, error: e.message)
  end

  # Capture the CLI-rotated tokens belonging to whoever currently owns the
  # filesystem credentials, so they aren't lost when write_config! overwrites
  # the file with a different account's config. Looks up the owner by the
  # ~/.claude.json identity rather than DB is_current?, because the two can
  # disagree (manual `claude auth login`, cross-container switches). Skips the
  # capture entirely when the filesystem identity matches the incoming
  # account or when there is no filesystem identity to capture from.
  def capture_outgoing_filesystem_tokens(except:)
    return if session_scoped_credentials?

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
    token = account.claude_access_token
    return unless token.present?

    result = QuotaCheckService.check_with_token(token)
    return unless result.success?

    QuotaSnapshotService.save_snapshot(account, result, trigger: trigger)
  rescue => e
    @logger.error("Failed to take quota snapshot", email: account.email, error: e.message)
    # Explicit, because #mark_outgoing! reads the return value and
    # StructuredLogger#error does not answer nil: it ends in
    # ErrorReporter.report_message, which returns a Sentry::Event whenever a DSN
    # is configured. That object is `present?` and answers no quota question, so
    # letting it fall out of here raises NoMethodError under the pool lock — on
    # the unprobeable-account path, which is exactly the one that must stay safe.
    nil
  end

  # Whether Claude sessions carry their own credentials rather than reading the
  # shared file. Read here rather than passed in, so a caller cannot half-apply
  # the setting by forgetting to thread it through.
  #
  # Deliberately the SETTING alone, not ClaudeSessionConfigDirectory.active_for?:
  # every caller here is deciding whether to WRITE the shared file, and the
  # spawn-time fallback that predicate also covers (no current account, no stored
  # token) is precisely the state in which there is nothing worth writing anyway.
  def session_scoped_credentials?
    AppSetting.session_scoped_credentials_enabled?
  end

  # Check if the current ~/.claude.json matches the account's stored config.
  #
  # Fails closed: a missing stored identity is a mismatch, not "can't verify,
  # assume ok" (#61). Answering ok is the one thing a safety check must not do
  # when it cannot verify — both callers use this to decide whether the filesystem
  # can be left alone, and an account with no stored identity is exactly the case
  # where the credentials on disk could belong to anyone.
  #
  # A mismatch is not a dead end. #ensure_active_account! first tries to adopt the
  # on-disk identity when it already names this account
  # (#adopt_own_filesystem_identity), which converges the unverifiable case
  # instead of repeating it, and otherwise writes the DB-current account to disk.
  def config_file_matches?(account)
    return false unless File.exist?(ClaudeAuthProvider::CLAUDE_JSON_PATH)

    stored_email = ClaudeAccount.extract_oauth_email(account.oauth_config&.dig("claude_json", "oauthAccount"))
    return false if stored_email.blank?

    current_config = JSON.parse(File.read(ClaudeAuthProvider::CLAUDE_JSON_PATH))
    ClaudeAccount.extract_oauth_email(current_config["oauthAccount"]) == stored_email
  rescue JSON::ParserError, Errno::ENOENT
    false
  end
end
