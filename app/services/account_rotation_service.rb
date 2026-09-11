# frozen_string_literal: true

# Manages rotation between Claude Code accounts when usage quotas are hit.
#
# Rotation is a database operation and nothing else: it marks the outgoing
# account, marks the incoming one current, and takes quota snapshots. Nothing is
# written to the worker's filesystem, because nothing reads one — every Claude
# session is spawned with its own CLAUDE_CONFIG_DIR and the current account's
# access token in CLAUDE_CODE_OAUTH_TOKEN (ClaudeSpawnEnv), so the next spawn
# picks up the new identity by reading the row. See issue #618.
#
# Usage:
#   service = AccountRotationService.new
#   result = service.rotate!
#   # => { success: true, account: <ClaudeAccount> }
#   # => { success: false, reason: "no_available_accounts" }
class AccountRotationService
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

  # Ensure there's a usable active account. Called on session start.
  #
  # The filesystem is not a party to this. There is no config file to compare
  # against, no identity to adopt and nothing to write: the session gets its
  # token from the current account's DB row via CLAUDE_CODE_OAUTH_TOKEN. What is
  # left is the part that was always the real work — make sure a usable account
  # is current and its access token is fresh. See issue #618.
  #
  # @return [ClaudeAccount, nil]
  def ensure_active_account!
    current = ClaudeAccount.current_account

    # `claude_access_token`, not just `has_valid_config?`: the token IS what the
    # session is handed, so a row carrying only a stored identity is not a usable
    # current account here even though the hash is non-empty. Keeping it current
    # would spawn token-less sessions while /health called the same row corrupt.
    # ...and not one Anthropic has already refused: the stored token IS the exact
    # string that would be exported as CLAUDE_CODE_OAUTH_TOKEN, so a recorded
    # refusal is a statement about it rather than about the account in general.
    if current&.active? && current&.claude_access_token.present? && !current.credential_rejected?
      if current.token_expired? || current.token_expiring_soon?
        @logger.info("Refreshing expired/expiring tokens for current account", email: current.email)
        @logger.warn("Token refresh failed for current account", email: current.email) unless current.refresh_token!
        current.reload
      end
      return current
    end

    # Pick the first available account whose credentials we can prove work.
    account = first_usable_available_account

    unless account
      # There is no filesystem fallback: adopting whatever tokens happen to be on
      # disk is the two-sources-of-truth problem this system was taken apart to
      # remove, and the answer is the Authenticate button on /inference, which
      # writes the DB and needs no shell.
      @logger.warn("No usable Claude account in the pool — authenticate one from /inference")
      return nil
    end

    account.mark_current!
    @logger.info("Set initial active account", email: account.email)
    account
  end

  # Activate a validated account: mark it current in the DB and take a quota
  # snapshot. Used by both the automatic rotation path (via
  # #activate_next_account) and the manual switch path (via
  # InferenceController#switch_account), so both entry points move the pool the
  # same way.
  #
  # Callers are responsible for validating the account's tokens before calling
  # this (e.g. via account.refresh_token!).
  #
  # There is nothing on the filesystem to capture or overwrite: a switch is a DB
  # write and a snapshot, and every session spawned after it reads the new
  # account's token out of the row. That is what collapses "Switch" from a
  # two-store reconciliation into one UPDATE — see issue #618.
  def activate!(account, snapshot_trigger:)
    account.mark_current!
    take_snapshot(account, trigger: snapshot_trigger)
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
  # probing Anthropic's OAuth endpoint before marking it current.
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

    # Validate the account's tokens by calling refresh_token! before marking it
    # current. The previous date-only check (token_expired? /
    # token_expiring_soon?) lets through bogus credentials with sentinel
    # expiresAt values (e.g., 9999999999999 from accidentally-loaded test
    # fixture data) or unexpired-but-revoked tokens. Either case hands every
    # subsequent session a token that 401s. Probing the OAuth endpoint catches
    # both.
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
  # validates like the other two (rotation, manual switch) rather than taking
  # `available.first` on faith. #ensure_fresh_tokens! swallows
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
    probed_token = account.claude_access_token
    # Nothing to present, so nothing a session could be handed. `available` only
    # requires a non-empty oauth_config, which a row holding just an identity
    # satisfies.
    if probed_token.blank?
      @logger.warn("Candidate holds no access token, skipping during bootstrap", email: account.email)
      return false
    end

    result = QuotaCheckService.check_with_token(probed_token)

    # The repair refresh is spent once per recorded refusal, not once per spawn.
    # A candidate that already carries one has been through this: the verdict is
    # about the token in the row right now (writing a new one retires it), so the
    # refresh that would have fixed a merely stale token has either already been
    # taken or was never going to help. Without the guard, a pool whose only
    # account has a working refresh endpoint and a dead subscription spends a
    # single-use token on every session spawn, forever — the shape #242 is about,
    # arrived at from a different direction.
    if result.credential_refused? && account.can_refresh_token? && !account.credential_rejected?
      @logger.info("Candidate's token was refused, refreshing before deciding", email: account.email)
      account.refresh_token!
      account.reload
      probed_token = account.claude_access_token
      result = QuotaCheckService.check_with_token(probed_token)
    end

    # The verdict this candidate was judged on, kept for the page that has to
    # explain the decision afterwards. Recorded here rather than at the first
    # probe above: a refusal we are about to try to repair with a refresh is not
    # a final answer about the account. See ClaudeAccount#record_credential_probe!.
    account.record_credential_probe!(result, probed_token: probed_token)

    if result.success?
      snapshot = QuotaSnapshotService.save_snapshot(account, result, trigger: "bootstrap")
      return true unless snapshot.seven_day_window_spent?

      @logger.warn("Candidate's live reading shows its 7-day window is spent, skipping during bootstrap",
        email: account.email)
      return false
    end

    if result.credential_refused?
      @logger.warn("Candidate's tokens were rejected by Anthropic, skipping during bootstrap",
        email: account.email, error: result.error_message)
      return false
    end

    # Unreachable, or answered with something that is not about authentication —
    # a 400 for a retired probe model, a 404, a proxy stripping the rate-limit
    # headers. Neither is a verdict on the credential, and skipping on one would
    # skip EVERY candidate at once: an Anthropic-side change becoming an
    # instance that cannot spawn. The same line the recorded verdict draws; see
    # QuotaCheckService::Result#credential_refused?.
    @logger.warn("Could not validate the candidate against Anthropic, promoting it unvalidated",
      email: account.email, error: result.error_message, unreachable: result.unreachable?)
    true
  end

  # True when the account's most recent quota reading says its weekly allowance is
  # gone. No snapshot means no evidence, which is not the same as bad evidence —
  # an account nobody has probed yet stays eligible.
  def quota_capped?(account)
    snapshot = account.latest_snapshot
    !snapshot.nil? && snapshot.seven_day_window_spent?
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
    account.record_credential_probe!(result, probed_token: token)
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
end
