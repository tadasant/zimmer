# frozen_string_literal: true

# Represents an agent-runtime account in the rotation pool.
#
# Despite the class name, this is the shared pool for every runtime Zimmer
# authenticates (Claude Code and Codex today) — the `runtime` column
# discriminates rows. Each account has its own credentials (stored in
# oauth_config) and can be rotated in/out when usage quotas are hit. Only one
# account per runtime is active (is_current) at a time — all sessions on the
# worker for that runtime share it.
#
# Credential shape by runtime (stored in oauth_config):
#   claude_code — { "claude_json" => {...}, "credentials_json" => {...} }
#                 (the shapes an interactive `claude auth login` writes into a
#                 scratch CLAUDE_CONFIG_DIR, captured verbatim). For Claude the
#                 row is the ONLY store: no session writes a credentials file,
#                 and each one is handed `credentials_json`'s access token
#                 through CLAUDE_CODE_OAUTH_TOKEN. See issue #618.
#   codex       — OAuth: { "auth_json" => {...} } (the contents of ~/.codex/auth.json,
#                 which the Codex CLI does still own and rotate)
#                 API key: { "api_key" => "sk-..." }
#
# Runtime-specific constants (token endpoints, client IDs, credential file
# paths) live in the matching provider — ClaudeAuthProvider and
# CodexAuthProvider — the single source of truth for each runtime's auth
# lifecycle. The token-introspection and refresh methods below dispatch on
# `runtime` so the generic refresh dispatcher can stay runtime-agnostic.
#
# Accounts are managed via rake tasks (one namespace per runtime):
#   bin/rails 'claude_accounts:add[email@example.com,0]'
#   bin/rails 'codex_accounts:add[email@example.com,0]'
#   bin/rails claude_accounts:list  /  bin/rails codex_accounts:list
class ClaudeAccount < ApplicationRecord
  # Agent runtimes that can own an account in this pool.
  RUNTIMES = %w[claude_code codex].freeze

  # Transient network failures raised while talking to a runtime's token
  # endpoint. These are self-recovering: RefreshRuntimeAuthTokensJob retries
  # with exponential backoff and escalates to .error only after retries are
  # exhausted. The refresh methods therefore log these at .info — a single
  # isolated blip must not trip the production ERROR-logs alert.
  TRANSIENT_REFRESH_ERRORS = [
    Net::OpenTimeout,
    Net::ReadTimeout,
    Errno::ECONNRESET,
    Errno::ECONNREFUSED,
    Errno::ETIMEDOUT,
    Errno::EHOSTUNREACH,
    Errno::ENETUNREACH,
    SocketError,
    OpenSSL::SSL::SSLError
  ].freeze

  # How many stale-looking refresh failures an account may collect before Zimmer
  # concludes the credential really is finished and asks a human to
  # re-authenticate it. A refresh token that a vendor answers with "not the
  # current value" proves nothing about the chain it belongs to, so one of them
  # is not evidence — three, spread out, are.
  STALE_REFRESH_STRIKE_LIMIT = 3

  # A streak expires six hours after its most recent strike, not six hours after
  # it started: three lost races a week apart are three unrelated races, and
  # forgetting the streak between them is the point.
  STALE_REFRESH_STRIKE_WINDOW = 6.hours

  # A second stale rejection this soon after the last one is the same episode.
  # refresh_token! has nine call sites — the Inference page, rotation, activation,
  # the quota-reset checker and the 5-minute sweep — and several of them can
  # present the same spent value within minutes of each other. That is one piece
  # of evidence, not five, so three strikes take at least half an hour.
  STALE_REFRESH_STRIKE_DEBOUNCE = 15.minutes

  enum :status, { active: 0, quota_exceeded: 1, needs_reauth: 2 }

  # Every association here is :nullify, and deliberately so. An account's quota
  # snapshots, login attempts, and rotation events are the only record of whether
  # it was ever healthy, and the operator gesture that most needs that record is
  # the one that removes the account — "delete it and re-authenticate", two
  # adjacent buttons on every /inference card. Deleting an account must stay possible
  # (:restrict_with_error would turn Delete into a dead control for any account
  # old enough to matter), so the history outlives the row rather than blocking
  # its removal. The database agrees: each of these foreign keys is ON DELETE SET
  # NULL, so a writer that skips these callbacks gets the same outcome.
  #
  # The orphans stay interpretable because each child row denormalizes the
  # account's identity (email, and the runtime that scopes it) at write time.
  # See ClaudeAccountQuotaSnapshot, RuntimeLoginAttempt, and AccountRotationEvent.
  has_many :quota_snapshots,
    class_name: "ClaudeAccountQuotaSnapshot",
    dependent: :nullify
  has_many :rotation_events_from,
    class_name: "AccountRotationEvent",
    foreign_key: :rotated_from_id,
    dependent: :nullify
  has_many :rotation_events_to,
    class_name: "AccountRotationEvent",
    foreign_key: :rotated_to_id,
    dependent: :nullify
  has_many :runtime_login_attempts, dependent: :nullify

  # Email uniqueness is scoped to runtime: the same person can hold one account
  # per runtime (e.g. a claude_code AND a codex account for tadas@tadasant.com).
  # Two accounts with the same email on the SAME runtime are still rejected.
  validates :email, presence: true, uniqueness: { scope: :runtime }
  validates :priority, numericality: { only_integer: true }
  validates :runtime, inclusion: { in: RUNTIMES }

  scope :available, -> { active.where.not(oauth_config: {}).order(:priority) }

  # The accounts whose stored access token Anthropic answered and refused — the
  # SQL form of #credential_rejected?, for the surfaces that want a count rather
  # than the rows. See #credential_state.
  scope :credential_refused, -> {
    where.not(credential_rejected_at: nil)
      .where("credential_verified_at IS NULL OR credential_rejected_at > credential_verified_at")
  }
  scope :for_runtime, ->(runtime) { where(runtime: runtime) }

  # The accounts that can serve a request for `runtime`, judged on the same
  # evidence #effective_status renders and QuotaResetCheckerJob restores on
  # rather than on the `status` column alone.
  #
  # `.available` reads that column, and the column is a claim about the past:
  # something writes `quota_exceeded` and only the 15-minute healer clears it
  # again. Two surfaces asking the same question through it, minutes apart, can
  # answer it opposite ways — see [One predicate for "is the pool drained"] in
  # docs/auth/harness.md. This is the one predicate the parking decision and
  # #auth_health ask, so they cannot.
  #
  # An account whose column says quota_exceeded while its reading says both
  # windows are clear counts as serviceable: the healer is about to restore it,
  # and until it runs the reading is the better evidence.
  #
  # **Only a reading the label has not already answered.** A label written AFTER
  # the newest reading was written by something that knew more than the reading
  # does — a runtime-observed quota refusal whose follow-up probe failed, say —
  # so overruling it would resurrect an account every spawn path still refuses,
  # and the healer's own fresh probe would decline to restore. Where the two
  # disagree in that direction the column wins, which is exactly `.available`.
  #
  # An account with no usable reading is likewise taken at its label. A Codex
  # account has no Anthropic quota window to read at all, so for a pool with no
  # snapshots this reduces to `.available` outright.
  #
  # @param runtime [String]
  # @return [Array<ClaudeAccount>] in priority order
  def self.serviceable_for(runtime)
    # Through the provider seam, so a blank runtime resolves to Claude Code the
    # same way every other pool read does. Scoping on the raw column here instead
    # would answer "no accounts" for a nil runtime, which reads as an outage.
    # `credential_refused` excludes an account whose stored token Anthropic
    # ANSWERED and refused, whatever its label and whatever its quota windows
    # say. That row is the 2026-07-31 state: `active`, credentials stored,
    # counted by every "is the pool dry" surface, and a 401 on every request made
    # with it (#239). Only an authentication-class refusal gets recorded, and the
    # verdict retires the moment a different token is written, so neither an
    # Anthropic blip nor a repaired account can strand the pool here.
    candidates = RuntimeAuthProvider.for(runtime).accounts
      .where(status: [ statuses[:active], statuses[:quota_exceeded] ])
      .where.not(oauth_config: {})
      .where.not(id: credential_refused.select(:id))
      .order(:priority)
      .to_a

    # Fetched only for the labelled accounts: an `active` one is serviceable on
    # its column alone, and #effective_status would not look at a reading anyway.
    labelled = candidates.reject(&:active?)
    snapshots = labelled.empty? ? {} : ClaudeAccountPool.latest_snapshots(labelled)

    candidates.select do |account|
      account.active? ||
        account.effective_status(reading_that_outranks_label(account, snapshots[account.id])) == "active"
    end
  end

  # The reading to judge `account`'s label by, or nil when the label is the newer
  # claim of the two and there is nothing to overrule it with.
  def self.reading_that_outranks_label(account, snapshot)
    return nil if snapshot.nil? || account.updated_at.nil?

    snapshot if snapshot.created_at > account.updated_at
  end
  private_class_method :reading_that_outranks_label

  # Does `runtime` have anything that can serve a request? The question every
  # "is the pool drained?" decision actually means to ask.
  def self.any_serviceable_for?(runtime)
    serviceable_for(runtime).any?
  end

  # An account that lands in needs_reauth is dead until a human re-authenticates,
  # and nothing else tells them. The transition is latched inside the transaction
  # and acted on after it commits, because the dirty state that identifies it does
  # not survive to the commit callback — see #latch_needs_reauth_transition.
  after_update :latch_needs_reauth_transition
  after_update_commit :notify_status_transition
  after_rollback :clear_needs_reauth_latch

  # A new refresh token is a new chain, and the strikes counted against the old
  # one say nothing about it. This catches the two ways a credential arrives
  # without a successful refresh: a human re-authenticating through /inference, and a
  # filesystem sync adopting the pair the CLI rotated on disk. Without it, an
  # account that was re-authed while carrying two strikes would be condemned again
  # on its first lost race.
  before_save :reset_stale_refresh_tracking_on_new_credential

  # A verdict is about the access token it was taken on. Writing a different one
  # — a refresh, a human re-auth, a filesystem sync — retires both the
  # verification and the refusal, and the row goes back to "stored, unverified"
  # until something probes it. See #credential_state.
  before_save :reset_credential_verdict_on_new_token

  # How long a single account's needs_reauth event stays suppressed after one is
  # emitted. Not a nicety: plenty of machinery writes `active` back onto a
  # needs_reauth row with no human involved — the auto-heal sweep on /inference, a
  # recovery probe that reaches Anthropic — and `ensure_active_account!` runs
  # before every session spawn, so an account can cross INTO needs_reauth many
  # times an hour without anyone doing anything. Unsuppressed, that is one
  # spawned agent session per spawn attempt.
  #
  # Twelve hours, matching the operator-DM window this replaces. The condition
  # stays broken until a human acts, and the sweeps that rediscover it run every
  # few minutes, so a shorter window buys nothing but noise.
  REAUTH_ALERT_THROTTLE = 12.hours

  # Postgres advisory lock namespace for serializing mutations of one runtime's
  # account pool (rotation, activation). Distinct from
  # Session::SESSION_ADVISORY_LOCK_NAMESPACE so the two subsystems can never
  # collide in the shared bigint key space. Fixed value — changing it would let
  # an old and a new deployment hold "the same" lock independently.
  POOL_ADVISORY_LOCK_NAMESPACE = 0x415F_4143 # "A_AC" ASCII — Account pool lock

  # How long a caller waits for another process's in-flight pool mutation before
  # giving up. A rotation is a handful of DB writes, two small filesystem writes
  # and at most one token refresh over HTTP, so it completes in seconds; a wait
  # this long means the holder is wedged, and the caller is better off reporting
  # "a rotation is in flight" than blocking its monitoring thread indefinitely.
  POOL_LOCK_WAIT = 45.seconds

  # Poll interval while waiting for the pool lock. pg_try_advisory_lock has no
  # blocking-with-timeout form, so the wait is a bounded poll.
  POOL_LOCK_POLL_INTERVAL = 0.25

  # Serialize a block against every other pool mutation for the same runtime,
  # across every process in the deployment.
  #
  # All sessions on a worker share ONE on-disk identity per runtime, so two
  # sessions that hit an auth wall at the same moment must not each rotate: the
  # second rotation would burn a perfectly good account the first had just
  # activated, and repeated across a fleet it drains the pool in seconds. This
  # lock is what makes "is a rotation already in flight?" answerable — a caller
  # that has to wait for it knows someone else is mid-rotation, and a caller
  # that gets it immediately knows nobody is.
  #
  # A session-level (not transaction-level) lock deliberately: rotation performs
  # an HTTP token refresh and filesystem writes, and wrapping those in a Postgres
  # transaction would hold it open across the network call — idle-in-transaction,
  # with the MVCC snapshot it pins. The connection is held either way; it is the
  # long-open transaction the session-level lock avoids.
  #
  # Nesting is safe: with_connection hands back the connection the thread already
  # has, so an inner acquire lands on the same backend, and Postgres counts
  # advisory locks per session — the inner unlock decrements, the outer releases.
  #
  # @param runtime [String] the runtime whose pool is being mutated
  # @param wait [ActiveSupport::Duration, Numeric] how long to wait for the lock
  # @return [Object, nil] the block's return value, or nil if the lock could not
  #   be acquired within `wait` (i.e. another process is mid-rotation and slow)
  def self.with_pool_lock(runtime, wait: POOL_LOCK_WAIT)
    key = pool_lock_key(runtime)
    deadline = Time.current + wait

    connection_pool.with_connection do |conn|
      acquired = try_pool_lock(conn, key)
      until acquired || Time.current >= deadline
        sleep(POOL_LOCK_POLL_INTERVAL)
        acquired = try_pool_lock(conn, key)
      end

      return nil unless acquired

      begin
        yield
      ensure
        # Swallow: if the connection died inside the block, raising here would
        # replace the real error with a confusing one — and a dead connection has
        # already released the lock.
        begin
          conn.execute(
            sanitize_sql_array([ "SELECT pg_advisory_unlock(?, ?)", POOL_ADVISORY_LOCK_NAMESPACE, key ])
          )
        rescue => e
          Rails.logger.warn "[ClaudeAccount] Could not release the pool lock: #{e.message}"
        end
      end
    end
  end

  # Stable 31-bit lock key for a runtime. Both pg_advisory_lock(int4, int4) args
  # must fit in a signed int4, so the digest is masked rather than truncated.
  def self.pool_lock_key(runtime)
    Digest::MD5.hexdigest(runtime.to_s).to_i(16) & 0x7FFF_FFFF
  end

  def self.try_pool_lock(conn, key)
    ActiveModel::Type::Boolean.new.cast(
      conn.select_value(
        sanitize_sql_array([ "SELECT pg_try_advisory_lock(?, ?)", POOL_ADVISORY_LOCK_NAMESPACE, key ])
      )
    )
  end
  private_class_method :try_pool_lock

  # Returns the DB-authoritative current account.
  #
  # For Claude Code this row is the whole answer: ClaudeSpawnEnv reads its
  # access token at every spawn and exports it as CLAUDE_CODE_OAUTH_TOKEN, so
  # there is no filesystem copy to reconcile against and no way for the two to
  # disagree. Codex still writes ~/.codex/auth.json before a spawn.
  #
  # Scoped to a runtime (defaults to Claude Code) because each runtime keeps
  # its own current account — only one row per runtime carries is_current.
  def self.current_account(runtime = ClaudeAuthProvider::RUNTIME)
    for_runtime(runtime).find_by(is_current: true)
  end

  # Extracts the email from a ~/.claude.json `oauthAccount` value, which the CLI
  # writes either as a plain string (legacy format) or as a Hash carrying
  # "emailAddress" (current format).
  #
  # The single implementation of that shape check: AccountRotationService and
  # ClaudeLoginDriver call this rather than keeping their own copies, so a third CLI
  # format can never be handled by two of the three and missed by the last.
  def self.extract_oauth_email(oauth_account)
    return nil if oauth_account.blank?

    oauth_account.is_a?(Hash) ? oauth_account["emailAddress"] : oauth_account
  end

  # True when this row carries SOMETHING in oauth_config. A structural check and
  # nothing more: it says a credential was stored, never that Anthropic or OpenAI
  # will honour it.
  #
  # Deliberately still `keys.any?`. Every caller that gates a real action on it —
  # the Codex provider's filesystem adoption, rotation's current-account branch,
  # the two rake listings — is asking "is there anything here to work with", and
  # tightening the predicate underneath them would change three runtimes' worth of
  # behaviour to fix a sentence on one page. What changed instead is that the UI
  # no longer uses this as a proxy for "usable": it renders #credential_state,
  # which is the evidence. See issue #239 and #record_credential_probe!.
  def has_valid_config?
    oauth_config.present? && oauth_config.is_a?(Hash) && oauth_config.keys.any?
  end

  # What the last non-consuming probe of the STORED access token learned, as one
  # of four states:
  #
  #   :none       — nothing stored. Authenticate it.
  #   :unverified — credentials are stored, and nothing has presented them to the
  #                 vendor since they were last written. The honest default: a
  #                 complete token pair is not a working one, which is the whole
  #                 lesson of 2026-07-31 (#239).
  #   :verified   — Anthropic answered a probe of this exact access token and
  #                 served it, at #credential_verified_at.
  #   :rejected   — Anthropic answered a probe of this exact access token and
  #                 refused it, at #credential_rejected_at. A session handed this
  #                 row would get "Not logged in".
  #
  # The verdict describes the token in the row, not the account in the abstract:
  # writing a different access token clears it (see
  # #reset_credential_verdict_on_new_token), so a refreshed or re-authenticated
  # account falls back to :unverified rather than carrying a stale claim. That is
  # what keeps a rejection from outliving the credential it was about — an
  # account whose refresh repairs it is serviceable again on the next save,
  # without anybody probing anything.
  #
  # "Unreachable" is never recorded, here or anywhere: an Anthropic blip is not a
  # verdict on a credential, and reading it as one would condemn the whole pool at
  # once (#259).
  #
  # Codex rows have no equivalent non-consuming probe, so they never leave :none
  # or :unverified and no surface claims otherwise.
  #
  # @return [Symbol]
  def credential_state
    return :none unless has_valid_config?
    return :rejected if credential_rejected?
    return :verified if credential_verified?

    :unverified
  end

  # True when the last answered probe of the stored token was a refusal.
  #
  # The two timestamps are compared rather than one being cleared by the other, so
  # a rejection recorded after a verification wins without either write having to
  # read the other first.
  def credential_rejected?
    return false if credential_rejected_at.blank?

    credential_verified_at.blank? || credential_rejected_at > credential_verified_at
  end

  def credential_verified?
    return false if credential_verified_at.blank?

    credential_rejected_at.blank? || credential_verified_at >= credential_rejected_at
  end

  # Record what a probe that has already happened learned about the access token
  # it was taken on.
  #
  # Costs nothing: every caller is holding a QuotaCheckService::Result it took for
  # its own reasons, so this adds no network request and — critically — spends no
  # single-use refresh token (#242). Call it only with a FINAL verdict: a refusal
  # a caller is about to try to repair with a refresh is not one.
  #
  # Three answers are recorded as nothing at all, and each for the same reason —
  # they are not evidence about the credential:
  #
  #   * the probe never reached Anthropic (#unreachable?),
  #   * Anthropic answered something that is not about authentication — a 400 for
  #     a retired model id, a 404, a proxy that strips the rate-limit headers
  #     (see QuotaCheckService::Result#credential_refused?),
  #   * there was no token to present.
  #
  # **The write is conditional on the row still holding the token that was
  # probed**, which is why `probed_token:` is required rather than re-read here.
  # The probe is an HTTP round trip, and RefreshRuntimeAuthTokensJob can rotate
  # this row inside it; without the condition a 401 about the token we sent would
  # be persisted as a refusal of the token that replaced it, dropping a healthy
  # account out of `.serviceable_for` until something probed it again.
  #
  # A conditional UPDATE rather than `update_columns`, and the choice is
  # load-bearing three times over. It is atomic against that racer; it must not
  # bump `updated_at`, because `.serviceable_for` compares a reading's
  # `created_at` against it to decide whether the reading outranks the status
  # label, and a probe that touched the row would make every fresh reading look
  # older than the label it was meant to overrule; and it must not fire callbacks
  # — recording a verdict is not a status transition and must not alert as one.
  #
  # @param result [QuotaCheckService::Result]
  # @param probed_token [String, nil] the access token the caller presented
  # @return [Symbol, nil] the state recorded, or nil when there was no verdict
  def record_credential_probe!(result, probed_token:)
    return nil if result.nil? || probed_token.blank?
    return nil unless result.success? || result.credential_refused?

    values =
      if result.success?
        # The reason is cleared with the verdict it belonged to: leaving it would
        # show a stale refusal next to a verified account on /supervisor.
        { credential_verified_at: Time.current, credential_rejection_reason: nil }
      else
        { credential_rejected_at: Time.current,
          credential_rejection_reason: result.error_message.to_s.truncate(255).presence }
      end

    return nil unless write_credential_verdict(values, probed_token)

    Rails.logger.warn "[ClaudeAccount] Anthropic refused #{email}'s stored access token: #{result.error_message}" unless result.success?
    result.success? ? :verified : :rejected
  rescue StandardError => e
    # Bookkeeping must never take down the path that was doing the real work —
    # every caller is mid-probe, mid-rotation or mid-login.
    Rails.logger.warn "[ClaudeAccount] Could not record the credential probe for #{email}: #{e.class} - #{e.message}"
    nil
  end

  # True when a credentials_json blob carries both an accessToken and a
  # refreshToken under claudeAiOauth.
  #
  # This is the single completeness invariant for Claude credentials. Anthropic
  # rotates AND invalidates the refresh token on every successful refresh, so a
  # credentials set that has an accessToken but no refreshToken is a dead end:
  # once that access token expires, nothing can mint a new one and the account is
  # unrecoverable without a fresh interactive login.
  #
  # The DB row is the only store now (issue #618), so this gates the two paths
  # that put a credential INTO it — an interactive login's capture, and the
  # health read that decides whether the pool can serve a session at all. An
  # incomplete set can never enter the pool and brick rotation. See
  # https://docs.zimmer.tadasant.com/auth/harness/.
  def self.complete_claude_oauth?(credentials_json)
    oauth = credentials_json.is_a?(Hash) ? credentials_json["claudeAiOauth"] : nil
    oauth.is_a?(Hash) && oauth["accessToken"].present? && oauth["refreshToken"].present?
  end

  def codex?
    runtime == CodexAuthProvider::RUNTIME
  end

  # The `id` tiebreaker matters because two readings can share a timestamp — a
  # rotation captures the outgoing and incoming accounts in the same instant, and
  # a test seeds a series without stamping distinct times. Ordering by time alone
  # then picks arbitrarily, and the spot gate would decide on either one.
  def latest_snapshot
    quota_snapshots.order(created_at: :desc, id: :desc).first
  end

  # The status this account should PRESENT, derived from its own latest quota
  # reading rather than taken on faith from the `status` column.
  #
  # `status` is sticky: something marks an account `quota_exceeded` and only
  # QuotaResetCheckerJob's 15-minute sweep ever clears it again. That makes the
  # column a claim about the past — true when it was written, and true
  # afterwards only for as long as the sweep keeps running and keeps agreeing.
  # It does not always: rotation stamps the outgoing account on its way past
  # (AccountRotationService#rotate_under_lock) whatever the reason it rotated
  # for, so an account rotated through on `auth_recovery` wears the label with no
  # quota evidence behind it at all; and a deployment whose queues stop draining
  # (#426 froze every one of them for ten hours) leaves every label frozen with
  # them. Both produce the same symptom — a card reading "Quota Exceeded" beside
  # two windows it says are Allowed at 35% and 12%.
  #
  # So the label reads the evidence directly. Same rule the healer restores on,
  # so the badge and the sweep cannot disagree; when they do differ it is only
  # ever because the sweep has not run yet, and the page tells the truth first.
  #
  # `status` stays load-bearing for `ClaudeAccount.available` and
  # AccountRotationService: every path that picks an account to spawn with must
  # keep acting on the durable column rather than on a reading that may be
  # minutes stale, and InferenceController converges the column separately
  # (#auto_heal_accounts).
  #
  # Two decisions read the evidence instead, through `.serviceable_for` — the
  # park decision and #auth_health — because for them the stale column errs the
  # dangerous way: it puts a session to sleep, and tells a human the pool is
  # gone, over a label the account's own newer reading contradicts.
  #
  # @param snapshot [ClaudeAccountQuotaSnapshot, nil] the reading to judge by;
  #   pass the one already loaded for the page to avoid a query per account.
  #   With no snapshot there is no evidence, so the column stands.
  # @return [String] an enum status name
  def effective_status(snapshot = latest_snapshot)
    return status unless quota_exceeded?
    return status if snapshot.nil?

    snapshot.windows_clear? ? "active" : status
  end

  def mark_quota_exceeded!
    update!(
      status: :quota_exceeded,
      quota_hit_count: quota_hit_count + 1
    )
  end

  # Mark this account as the current one for its runtime. Scoped to the same
  # runtime so activating (e.g.) a Codex account doesn't clear the Claude
  # pool's current flag — each runtime keeps an independent current account.
  def mark_current!
    self.class.for_runtime(runtime).where.not(id: id).update_all(is_current: false)
    update!(is_current: true, last_rotated_to_at: Time.current)
  end

  # Returns the token expiration time derived from oauth_config, or nil when the
  # account never expires (API-key accounts) or has no token data.
  # @return [Time, nil]
  def token_expires_at
    codex? ? codex_token_expires_at : claude_token_expires_at
  end

  def token_expired?
    return codex_token_expired? if codex?

    expires = claude_token_expires_at
    expires.nil? || expires <= Time.current
  end

  def token_expiring_soon?(threshold = 15.minutes)
    return codex_token_expiring_soon?(threshold) if codex?

    expires = claude_token_expires_at
    return false if expires.nil?
    expires < threshold.from_now
  end

  # Returns true if the account has a refresh token that can be used.
  # API-key Codex accounts have nothing to refresh and return false.
  def can_refresh_token?
    if codex?
      codex_refresh_token.present?
    else
      claude_refresh_token.present?
    end
  end

  # The Claude subscription access token this account would present, from its DB
  # copy — the single reader for a dig that seven callers used to spell out
  # themselves. nil for a Codex row or an account with no captured credentials.
  #
  # This is the value handed to a session as CLAUDE_CODE_OAUTH_TOKEN under
  # session-scoped credentials, which is why it is one method: the token a
  # session runs on and the token Zimmer probes quota with must not be able to
  # drift apart.
  def claude_access_token
    return nil if codex?

    oauth_config&.dig("credentials_json", "claudeAiOauth", "accessToken").presence
  end

  # Refreshes the access token using the runtime's OAuth refresh_token grant.
  # Updates oauth_config in the DB and writes to the runtime's credential file
  # if this is the current account.
  #
  # @return [true] if refresh succeeded (or there is nothing to refresh)
  # @return [false] if refresh failed
  # @param recovery_probe [Boolean] when true, this is a best-effort probe of an
  #   account already known to be in needs_reauth (see
  #   RuntimeAuthProvider#recover_needs_reauth). An expected probe failure is logged
  #   at .info rather than .error/.warn — the real failure already alerted when the
  #   account first transitioned to needs_reauth, and a known-dead token fails every
  #   cycle until a human re-authenticates.
  # True when this account's STORED access token is one Anthropic still honours
  # right now.
  #
  # A cheaper and strictly safer readiness probe than #refresh_token!: it proves
  # the account can serve a session immediately, and unlike a refresh it does not
  # spend the single-use refresh token. Every place that only needs to know
  # "can this account work" should ask this first and fall back to a refresh only
  # when the answer is no — a refresh round trip as the ADMISSION test is what
  # made repairing an account require the very thing that was broken about it
  # (issue #618, hole 4).
  #
  # Claude only: Codex accounts have no equivalent non-consuming probe, so they
  # answer false and take the refresh path they already took.
  #
  # An unreachable Anthropic answers false too (a probe that never arrived is not
  # a verdict, and reporting it as one would be a false GO here), so callers
  # degrade to the refresh path rather than admitting an unverified account on a
  # network blip.
  def access_token_honored?
    return false if codex?
    return false if token_expired?

    token = claude_access_token
    return false if token.blank?

    result = QuotaCheckService.check_with_token(token)
    # The probe happened either way, so the page may as well learn from it. A
    # refusal recorded here is about the token we just presented; the caller's
    # fallback refresh writes a new one, which retires the verdict.
    record_credential_probe!(result, probed_token: token)
    result.success?
  rescue StandardError => e
    Rails.logger.info "[ClaudeAccount] Access-token probe for #{email} was inconclusive: #{e.message}"
    false
  end

  def refresh_token!(recovery_probe: false)
    @last_refresh_failure_kind = nil

    # API-key Codex accounts authenticate statically — nothing to rotate, nothing
    # to race, so they skip the lock entirely.
    return true if codex? && codex_api_key_account?

    # Both vendors issue SINGLE-USE refresh tokens: a successful refresh returns a
    # new pair and invalidates the old one. Two callers presenting the same token
    # means the second is told the token is invalid (`invalid_grant` from Anthropic,
    # `refresh_token_reused` from OpenAI) — indistinguishable, from the response
    # alone, from a genuinely dead credential — and the account is marked
    # needs_reauth. That is how a healthy pool drains itself one account at a
    # time (#242): four different accounts died that way in ten days.
    #
    # Callers reach this from the Inference page, the quota-reset checker, the refresh
    # sweep, rotation, activation and needs_reauth recovery, so the serialization
    # lives HERE rather than at each of them: a row lock held across the whole
    # read-refresh-persist sequence, which is the only scope that can promise the
    # token we present is the token we hold. Bounded by the HTTP timeouts each
    # runtime's refresh sets (5s open, 10s read), and re-entrant with the outer
    # with_lock that ClaudeAuthProvider#recover_needs_reauth and
    # RefreshRuntimeAuthTokensJob already take.
    #
    # Captured before with_lock, which reloads the row — so the comparison inside
    # tells "the token moved while I queued" from "the token is what I saw".
    token_before_lock = current_refresh_token
    refreshed = false

    with_lock do
      # Whoever held the lock before us may have already done this work. Their new
      # pair is on the row we just re-read, so refreshing again would consume a
      # token nobody has used yet. Their refresh is our refresh.
      #
      # The token moving is necessary evidence but not sufficient: a plain
      # filesystem sync also rewrites it, and a caller whose HTTP refresh then
      # failed leaves a moved token behind without having refreshed anything. So
      # also require the access token to be good — otherwise we would report
      # success to callers (rotation, the Inference page) that asked precisely so
      # they could avoid writing stale credentials to disk.
      if token_before_lock.present? && current_refresh_token.present? &&
          current_refresh_token != token_before_lock && !token_expiring_soon?
        Rails.logger.info "[ClaudeAccount] Refresh for #{email} already performed by a concurrent caller, skipping"
        refreshed = true
        next
      end

      refreshed = if codex?
        refresh_codex_token!(recovery_probe: recovery_probe)
      else
        # No filesystem read before the refresh. A Claude session receives an
        # access token and no refresh token, so nothing but this row has ever
        # held the chain — there is no second copy to adopt (issue #618).
        perform_claude_refresh!(recovery_probe: recovery_probe, presented: claude_refresh_token)
      end
    end

    refreshed
  rescue StandardError => e
    # with_lock sits outside the per-runtime refresh bodies' own rescues, so a
    # lock timeout or deadlock would otherwise escape from a method every caller
    # treats as returning a boolean — 500ing the Inference page and aborting a
    # rotation mid-flight. Preserve the "returns false, never raises" contract.
    Rails.logger.error "[ClaudeAccount] Token refresh could not acquire or hold the account lock for #{email}: #{e.message}"
    false
  end

  # Why the last #refresh_token! call failed, for the callers that have to decide
  # what to do next.
  #
  #   :needs_reauth - the account was condemned; only a human clears it
  #   :stale        - the vendor rejected the VALUE. Retrying would present the
  #                   same one, so a retry ladder is wasted requests
  #   :transient    - a network blip or an unrecognised response; worth retrying
  #
  # @return [Symbol, nil] nil when the last call succeeded
  def last_refresh_failure_reason
    return :needs_reauth if needs_reauth?

    @last_refresh_failure_kind == :stale ? :stale : :transient
  end

  # The refresh token currently stored on this row, whichever runtime owns it.
  def current_refresh_token
    codex? ? codex_refresh_token : claude_refresh_token
  end

  # The refresh token currently stored on this row.
  def claude_refresh_token
    oauth_config&.dig("credentials_json", "claudeAiOauth", "refreshToken")
  end

  # True when the token we just presented is no longer the token of record —
  # someone rotated it while our request was in flight, so the `invalid_grant` we
  # got back says "already spent", not "dead".
  #
  # For a Claude row the row lock in #refresh_token! is the whole story: a
  # session is handed an access token and never a refresh token, so no CLI
  # process can rotate the chain and there is no writer left to lose a race to.
  # A Codex row still re-syncs from its own auth.json, which the Codex CLI does
  # rotate.
  #
  # When it cannot tell — no token to compare, or the sync raising — it answers
  # "not a race", which condemns the account. That is the deliberate direction:
  # a wrongly-condemned account is picked back up by
  # RuntimeAuthProvider#recover_needs_reauth, which probes needs_reauth accounts
  # and restores the ones that work, whereas an account wrongly spared is never
  # marked and so never surfaces to the human who has to re-authenticate it. The
  # recoverable mistake is the one to make.
  def lost_refresh_race?(presented)
    return false if presented.blank?

    sync_codex_tokens_from_filesystem! if codex?
    reload
    current_token = current_refresh_token

    current_token.present? && current_token != presented
  rescue => e
    Rails.logger.warn "[ClaudeAccount] Could not check for a lost refresh race on #{email}: #{e.message}"
    false
  end
  private :lost_refresh_race?

  # The read-refresh-persist body of #refresh_token!, run with the row lock held.
  #
  # Private, and `presented:` is required with no fallback: called without it, the
  # method would send one token and then compare a nil against it, which reads as
  # "not a race" and condemns the account — reintroducing #242 through the back
  # door. A missing argument must be a load error, not a production needs_reauth.
  #
  # @param presented [String] the refresh token being sent to Anthropic, so a
  #   failure can tell whether the token moved underneath the attempt.
  def perform_claude_refresh!(presented:, recovery_probe: false)
    refresh_tok = presented
    raise "Cannot refresh: missing refresh token for #{email}" unless refresh_tok.present?

    uri = URI(ClaudeAuthProvider::TOKEN_ENDPOINT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10
    request = Net::HTTP::Post.new(uri.path)
    request.set_form_data({
      grant_type: "refresh_token",
      refresh_token: refresh_tok,
      client_id: ClaudeAuthProvider::CLIENT_ID
    })
    response = http.request(request)

    if response.code.start_with?("2")
      token_data = JSON.parse(response.body)
      new_expires_at_ms = token_data["expires_in"] ? ((Time.current + token_data["expires_in"].to_i.seconds).to_f * 1000).to_i : nil

      updated_credentials = oauth_config.deep_dup
      claude_oauth = updated_credentials.dig("credentials_json", "claudeAiOauth") || {}
      claude_oauth["accessToken"] = token_data["access_token"]
      claude_oauth["refreshToken"] = token_data["refresh_token"] || refresh_tok
      claude_oauth["expiresAt"] = new_expires_at_ms if new_expires_at_ms
      updated_credentials["credentials_json"] ||= {}
      updated_credentials["credentials_json"]["claudeAiOauth"] = claude_oauth

      # Persisting the new pair is the step that must not fail: Anthropic spent the
      # token we presented the moment it answered, so this row now holds the only
      # copy of the credential chain. Clearing the stale-failure strikes in the
      # same statement keeps the two consistent — a working refresh is the end of
      # whatever streak preceded it.
      # Nothing follows the persist. The row IS the credential: the next session
      # to spawn reads this access token out of it via CLAUDE_CODE_OAUTH_TOKEN,
      # so there is no second store to converge and no window in which the two
      # disagree (issue #618).
      update!(oauth_config: updated_credentials, stale_refresh_failures: 0, last_stale_refresh_failure_at: nil)

      Rails.logger.info "[ClaudeAccount] Token refresh succeeded for #{email}"
      true
    elsif recovery_probe
      Rails.logger.info "[ClaudeAccount] Recovery probe for #{email} still failing (#{response.code}); awaiting re-auth"
      false
    else
      handle_refresh_rejection(response, presented: presented, kind: claude_refresh_failure_kind(response))
    end
  rescue StandardError => e
    if recovery_probe
      Rails.logger.info "[ClaudeAccount] Recovery probe error for #{email}: #{e.message}; awaiting re-auth"
    elsif transient_refresh_error?(e)
      # The refresh job retries transient failures with backoff and escalates
      # to .error only once retries are exhausted, so log at .info here.
      Rails.logger.info "[ClaudeAccount] Token refresh transient error for #{email}: #{e.class} - #{e.message} (will retry)"
    else
      Rails.logger.error "[ClaudeAccount] Token refresh error for #{email}: #{e.message}"
    end
    false
  end
  private :perform_claude_refresh!

  # --- Codex identity accessors (used by CodexAuthProvider for fs reconciliation) ---

  # The ChatGPT account_id embedded in this Codex account's OAuth tokens, used to
  # match the filesystem identity. nil for API-key accounts.
  def codex_account_id
    codex_tokens&.dig("account_id")
  end

  # The OPENAI_API_KEY for an API-key Codex account, or nil for OAuth accounts.
  def codex_api_key
    oauth_config&.dig("api_key").presence || codex_auth_json&.dig("OPENAI_API_KEY").presence
  end

  # True when this Codex account authenticates with a static API key (nothing to
  # refresh, never expires) rather than rotating ChatGPT OAuth tokens.
  def codex_api_key_account?
    codex_api_key.present? && codex_refresh_token.blank?
  end

  # Reads ~/.codex/auth.json and, when its ChatGPT account_id matches this
  # account, captures the tokens (and last_refresh) the Codex CLI rotated on
  # disk back into oauth_config. Gated on identity: we only adopt filesystem
  # tokens we can prove belong to this account, so a different active account's
  # credentials are never written onto this row. Codex keeps this path because
  # the Codex CLI still owns and rotates ~/.codex/auth.json; Claude's equivalent
  # is gone (issue #618).
  def sync_codex_tokens_from_filesystem!
    return unless codex?
    return unless File.exist?(CodexAuthProvider::AUTH_JSON_PATH)

    fs = JSON.parse(File.read(CodexAuthProvider::AUTH_JSON_PATH))
    fs_tokens = fs["tokens"]
    unless fs_tokens.is_a?(Hash) && fs_tokens["account_id"].present? && fs_tokens["account_id"] == codex_account_id
      Rails.logger.info "[ClaudeAccount] Skipping codex filesystem sync for #{email}: filesystem identity is #{fs_tokens.is_a?(Hash) ? fs_tokens["account_id"].inspect : "absent"}"
      return
    end

    if fs_tokens["access_token"].blank? || fs_tokens["refresh_token"].blank?
      Rails.logger.warn "[ClaudeAccount] Skipping codex filesystem sync for #{email}: filesystem tokens are incomplete (missing access_token or refresh_token)"
      return
    end

    unless codex_auth_at_least_as_new_on_disk?(fs)
      Rails.logger.info "[ClaudeAccount] Skipping codex filesystem sync for #{email}: the stored tokens are newer than the ones on disk"
      return
    end

    updated = oauth_config.deep_dup
    updated["auth_json"] = fs
    update!(oauth_config: updated)
  rescue JSON::ParserError => e
    Rails.logger.warn "[ClaudeAccount] Failed to parse codex auth.json: #{e.message}"
  end

  # Writes this Codex account's credentials to ~/.codex/auth.json so the next
  # CLI spawn authenticates as it. OAuth accounts write their stored auth.json
  # verbatim (preserving fields Zimmer doesn't model); API-key accounts write a
  # minimal { "OPENAI_API_KEY" => key } envelope.
  def write_codex_auth_to_filesystem!
    auth_json = codex_auth_json.presence || ({ "OPENAI_API_KEY" => codex_api_key } if codex_api_key.present?)
    return unless auth_json.present?

    FileUtils.mkdir_p(CodexAuthProvider::CODEX_HOME)
    File.write(CodexAuthProvider::AUTH_JSON_PATH, JSON.pretty_generate(auth_json))
  end

  # Release the alert throttle so the NEXT time this account dies, it says so
  # immediately rather than waiting out REAUTH_ALERT_THROTTLE.
  #
  # Called from the login drivers' `capture!` and nowhere else, because a human
  # completing a login is the only event that means "this is genuinely fixed".
  # Plenty of machinery writes `active` without a human involved (the auto-heal
  # sweep, the recovery probe); releasing on those would let an account that is
  # condemned again seconds later alert again, which is the flood the throttle
  # exists to stop.
  #
  # `update_columns`, not `update!`: this must not itself look like a status
  # transition, and it runs immediately after one.
  #
  # Rescued because it is the LAST statement of a successful `capture!`, after the
  # credentials have already been persisted. An exception here would propagate out
  # of the login driver and make RuntimeLoginJob mark the attempt failed — showing
  # the human a failed login panel for a login that actually worked. Losing the
  # release only costs one throttle window.
  def clear_reauth_alert!
    update_columns(reauth_alerted_at: nil)
    true
  rescue => e
    Rails.logger.warn "[ClaudeAccount] Could not release the reauth alert throttle for #{email}: #{e.class} - #{e.message}"
    false
  end

  private

  # Emit the `account_needs_reauth` Zimmer event when this account crosses INTO
  # needs_reauth.
  #
  # Zimmer does not compose the notification itself. The event fires whatever
  # `ao_event` triggers watch it, and the one this deployment seeds spawns a
  # `general-agent` session holding the `slack-workspace` MCP server, which sends
  # the DM. That indirection is the point: the notification is configurable at
  # /triggers instead of compiled in, and its failures land in a session
  # transcript instead of in a swallowed `.warn`.
  #
  # A model callback rather than instrumentation at the call sites, so no path
  # that condemns an account can forget to alert — including the Administrate
  # admin form, which no service-level hook would see.
  #
  # Two exclusions fall out of this placement, and both are correct:
  #
  # - **Creation.** `after_update_commit` does not fire on insert, so the
  #   credential-less account InferenceController seeds directly into needs_reauth
  #   does not alert. The human is on the page adding it; telling them to go to the
  #   page they are on is noise.
  #
  # - **Recovery restores.** {ClaudeAuthProvider#recover_needs_reauth} (and its
  #   Codex twin) flips an already-dead account to active so `refresh_token!`
  #   is not status-blocked, then writes needs_reauth back with `update_columns`
  #   when the probe fails. `update_columns` skips callbacks, so those restores
  #   are silent — which is what we want: the account was already needs_reauth
  #   before recovery started, so that is a no-op round trip, not a new failure.
  #   The probe itself cannot condemn the account either (`recovery_probe: true`
  #   returns before the permanent-failure branch in `perform_claude_refresh!`).
  #   Without both of those, every recovery sweep would look like a fresh
  #   transition and re-nag on the dedup window's clock.
  #
  # Note what this does NOT do: release the throttle when an account leaves
  # needs_reauth. That was the first shape of this callback and it was wrong.
  # Plenty of machinery writes `active` with a plain `update!` and no human
  # involved — the auto-heal sweep on /inference, a recovery probe that happens to
  # succeed — and `ensure_active_account!` runs before every session spawn.
  # Releasing there would drop the throttle moments before `usable_candidate?`
  # re-condemns the same account, turning a drained pool into one spawned session
  # per spawn attempt: exactly the flood the window exists to prevent. Releasing
  # is therefore the job of the human re-auth path alone, where it means what it
  # says — see #clear_reauth_alert! and ClaudeLoginDriver#capture!.
  # Record, at save time, that this save crossed into needs_reauth — so that
  # #notify_status_transition can still tell after the transaction commits.
  #
  # It cannot ask `saved_change_to_status?` itself, and that is not a stylistic
  # preference: `reload` nils `@mutations_before_last_save`
  # (ActiveRecord::AttributeMethods::Dirty#reload), so any reload between the save
  # and the commit erases the evidence. `RefreshRuntimeAuthTokensJob` — the
  # every-5-minutes sweep, and the likeliest discoverer of a dead refresh token —
  # does exactly that: it wraps the refresh in an outer `account.with_lock`, and
  # `ClaudeAuthProvider#refresh!` reloads on its failure branch to classify the
  # error. `with_lock` opens a transaction without `requires_new`, so
  # `refresh_token!`'s inner lock JOINS it and the commit callback does not run
  # until that outer transaction commits — by which time the reload has already
  # happened. Asking at commit time answered "no status change" and the DM was
  # silently skipped on precisely the path that matters most.
  #
  # A plain ivar survives `reload`, so latching here and reading it there is what
  # closes that gap. Only a save that actually moved `status` touches the latch:
  # a later non-status save in the same transaction must not clear a pending
  # transition, and a later save that moves status back OUT of needs_reauth must.
  def latch_needs_reauth_transition
    return unless saved_change_to_status?

    @crossed_into_needs_reauth = needs_reauth?
  end

  def clear_needs_reauth_latch
    @crossed_into_needs_reauth = false
  end

  def notify_status_transition
    return unless @crossed_into_needs_reauth
    return unless claim_reauth_alert_slot!

    begin
      AoEventTriggerJob.perform_later("account_needs_reauth", id)
    rescue
      # The slot was claimed for an event that never reached the queue. Give it
      # back, or this account stays silent for the whole throttle window over a
      # transient enqueue failure — a suppression that suppresses nothing.
      clear_reauth_alert!
      raise
    end
  rescue => e
    # Never let alerting break the auth path. This runs after commit, so the
    # status change is already durable; losing the notification is survivable,
    # raising here is not.
    #
    # .warn rather than .error: a plain ERROR line trips the "any Zimmer ERROR →
    # critical" Grafana rule (see ApplicationJob), and paging critically about one
    # lost notification would be an alert about the alerting path.
    Rails.logger.warn "[ClaudeAccount] Failed to dispatch status-transition alert for #{email}: #{e.class} - #{e.message}"
  ensure
    # One latch, one event. Without this a later save on the same in-memory record
    # would re-enqueue the alert it already sent.
    @crossed_into_needs_reauth = false
  end

  # Take the one alert slot this account has per REAUTH_ALERT_THROTTLE, returning
  # false when it is already taken.
  #
  # Claimed at EMIT time, before the event is enqueued, because that is the only
  # point that serializes concurrent condemnations of the same account. The cost
  # is that a claim can outlive an event that delivers nothing, so every path
  # which ends without a notification gives the slot back: the enqueue rescue
  # below, and AoEventSubject::AccountSubject#stale? when the account recovered
  # before the job ran.
  #
  # A single conditional UPDATE, so two workers condemning the same account in the
  # same instant cannot both win it — the loser's WHERE matches zero rows. That is
  # the whole reason this lives in the database rather than in Rails.cache, where
  # its predecessor lived: a cache-backed suppressor fails OPEN when the cache is
  # unreachable, and "one agent session per spawn attempt" is the wrong way to
  # fail. It is also readable after the fact, which a cache key never was.
  #
  # `update_all` deliberately skips callbacks: this runs from inside one.
  def claim_reauth_alert_slot!
    now = Time.current
    self.class
      .where(id: id)
      .where("reauth_alerted_at IS NULL OR reauth_alerted_at < ?", now - REAUTH_ALERT_THROTTLE)
      .update_all(reauth_alerted_at: now)
      .positive?
  end

  # True when an exception raised during token refresh is a transient network
  # failure (see TRANSIENT_REFRESH_ERRORS). Such failures are retried by the
  # refresh job, so they are logged at .info rather than tripping the ERROR alert.
  def transient_refresh_error?(error)
    TRANSIENT_REFRESH_ERRORS.any? { |klass| error.is_a?(klass) }
  end

  # Standard OAuth error codes that mean the token endpoint rejected our
  # credential rather than failing to answer. Only two of the three are about the
  # credential being dead — see #claude_refresh_failure_kind for invalid_grant.
  REJECTED_OAUTH_ERRORS = %w[invalid_grant invalid_client unauthorized_client].freeze

  # Anthropic error types that indicate the refresh token is permanently invalid.
  # Anthropic uses a nested format: {"error": {"type": "...", "message": "..."}}
  PERMANENT_ANTHROPIC_ERROR_TYPES = %w[invalid_request_error authentication_error].freeze

  # The `error_description` values Anthropic returns for a credential that is
  # genuinely finished, as opposed to a value that has simply been superseded.
  DEAD_CREDENTIAL_DESCRIPTIONS = /expired|revoked/i

  # What a rejected refresh actually proves.
  #
  #   :dead    - the credential itself is finished: expired, revoked, or issued to
  #              a client we are not. Only a human can fix it.
  #   :stale   - the VALUE we presented is not the current one. That says nothing
  #              about the chain it belongs to, which is usually alive and exactly
  #              one rotation ahead of us.
  #   :unknown - not a recognised auth rejection at all (5xx, a proxy's HTML, a
  #              body we cannot parse). The refresh path itself may be broken.
  #
  # Anthropic separates the first two in `error_description` and nowhere else:
  # both arrive as a 400 `invalid_grant`, but "Refresh token expired" is a dead
  # credential while "Refresh token not found or invalid" is a spent value. Over
  # eleven days of production logs, 14 of 15 accounts condemned to needs_reauth
  # carried the second string — they were stale, not dead. See
  # https://github.com/tadasant/zimmer/issues/530.
  def claude_refresh_failure_kind(response)
    return :dead if %w[401 404].include?(response.code)
    return :unknown unless response.code == "400"

    begin
      body = JSON.parse(response.body)
    rescue JSON::ParserError
      return :unknown
    end
    return :unknown unless body.is_a?(Hash)

    error_field = body["error"]

    # Anthropic format: {"error": {"type": "invalid_request_error", "message": "..."}}
    if error_field.is_a?(Hash)
      return PERMANENT_ANTHROPIC_ERROR_TYPES.include?(error_field["type"]) ? :dead : :unknown
    end

    # Standard OAuth format: {"error": "invalid_grant"}
    return :unknown unless error_field.is_a?(String) && REJECTED_OAUTH_ERRORS.include?(error_field)

    # invalid_client / unauthorized_client are verdicts on the client, not on the
    # token, and retrying cannot change them.
    return :dead unless error_field == "invalid_grant"

    DEAD_CREDENTIAL_DESCRIPTIONS.match?(body["error_description"].to_s) ? :dead : :stale
  end

  # The shared "the token endpoint said no" branch for both runtimes.
  #
  # The order matters. A race that can be *proved* spares the account outright.
  # A response that proves the credential is dead condemns it outright. Everything
  # in between — the case that made this account pool flap, where the value was
  # rejected but nothing says the chain behind it is gone — collects a strike and
  # is left alone until the strikes say otherwise.
  def handle_refresh_rejection(response, presented:, kind:)
    @last_refresh_failure_kind = kind
    label = codex? ? "Codex refresh" : "Refresh"

    if kind == :unknown
      # An unexpected non-2xx response — neither a recognised OAuth rejection nor
      # a retried transient exception — means the refresh path is genuinely broken.
      # Keep this at .error so a true persistent refresh outage still pages.
      Rails.logger.error "[ClaudeAccount] #{codex? ? "Codex token" : "Token"} refresh failed for #{email}: #{response.code} - #{response.body}"
      return false
    end

    if lost_refresh_race?(presented)
      # The row lock above rules out another Zimmer caller, but not the agent CLI,
      # which rotates the shared credentials file on its own during a session. So:
      # re-sync from disk and see whether the token we presented is still the token
      # of record. If it moved, we lost a race and the account is fine.
      Rails.logger.warn "[ClaudeAccount] #{label} for #{email} lost a race with a concurrent token rotation; " \
        "the stored token has moved on, so the account is healthy and is NOT being marked needs_reauth"
      clear_stale_refresh_failures!
      return false
    end

    if kind == :stale && !record_stale_refresh_failure!
      # This is the branch #530 exists for. `lost_refresh_race?` can only see a
      # rotation that landed on disk, and the disk holds one account's credentials
      # at a time — so for every account that is not the current credentials owner
      # it has no evidence at all and answers "not a race". Condemning on that
      # answer is condemning on nothing. Wait for a pattern instead.
      Rails.logger.warn "[ClaudeAccount] #{label} for #{email} was rejected as a spent token value " \
        "(strike #{stale_refresh_failures}/#{STALE_REFRESH_STRIKE_LIMIT}); nothing here proves the credential is dead, " \
        "so the account is NOT being marked needs_reauth: #{response.body}"
      return false
    end

    # Either the credential is provably dead (expired, revoked, 401, 404) or it has
    # been rejected as stale often enough, for long enough, that a live chain no
    # longer explains it. The account is marked needs_reauth and rotated out of the
    # active pool, so this is expected and handled: log at .warn, not .error, so it
    # does not page on a recoverable condition (the human re-auths to recover).
    Rails.logger.warn "[ClaudeAccount] #{label} token permanently invalid for #{email} (#{response.code}), marking needs_reauth: #{response.body}"
    update!(status: :needs_reauth)
    # The strikes have done their job and the row is now condemned by status. Left
    # standing, they would deny the next credential its benefit of the doubt: an
    # account flipped back to active from the admin form, without a new token,
    # would be condemned again by a single stale rejection.
    clear_stale_refresh_failures!
    false
  end

  # Count one refresh that was rejected without proof the credential is dead, and
  # answer whether that is now enough to condemn the account.
  #
  # Written with update_columns so it survives as bookkeeping rather than as a
  # model event: it must not fire the needs_reauth alert callbacks, and it must not
  # be undone by a validation on some other attribute.
  #
  # @return [Boolean] true when the account has run out of benefit of the doubt
  def record_stale_refresh_failure!
    last = last_stale_refresh_failure_at

    strikes =
      if last.blank? || last < STALE_REFRESH_STRIKE_WINDOW.ago
        1
      elsif last > STALE_REFRESH_STRIKE_DEBOUNCE.ago
        # Same episode — no new evidence, so no new strike. Answer on the strikes
        # already banked rather than a flat "spare it", so a row that somehow
        # arrives here already at the limit is not spared forever.
        return stale_refresh_failures >= STALE_REFRESH_STRIKE_LIMIT
      else
        stale_refresh_failures + 1
      end

    update_columns(stale_refresh_failures: strikes, last_stale_refresh_failure_at: Time.current)
    strikes >= STALE_REFRESH_STRIKE_LIMIT
  end

  # Codex's auth.json carries a last_refresh that both the CLI and Zimmer stamp
  # on every rotation, so "do not move backwards" is answerable directly. A disk
  # copy older than the one we hold is the residue of a write that did not land,
  # and adopting it would overwrite the only live refresh token with one OpenAI
  # has already spent.
  def codex_auth_at_least_as_new_on_disk?(fs_auth)
    on_disk = fs_auth["last_refresh"]
    stored = codex_auth_json&.dig("last_refresh")
    return true if on_disk.blank? || stored.blank?

    Time.parse(on_disk.to_s) >= Time.parse(stored.to_s)
  rescue ArgumentError, TypeError
    true
  end

  def clear_stale_refresh_failures!
    return if stale_refresh_failures.zero? && last_stale_refresh_failure_at.blank?

    update_columns(stale_refresh_failures: 0, last_stale_refresh_failure_at: nil)
  end

  # See the before_save that calls this.
  def reset_stale_refresh_tracking_on_new_credential
    return unless will_save_change_to_oauth_config?

    before, after = oauth_config_change_to_be_saved
    return if refresh_token_in(before) == refresh_token_in(after)

    self.stale_refresh_failures = 0
    self.last_stale_refresh_failure_at = nil
  end

  # Apply a verdict only while the row still holds `probed_token`, and mirror it
  # onto this instance when it lands. See #record_credential_probe!.
  #
  # **The token never enters SQL; its SHA-256 does.** Production's Sentry SDK
  # records every `sql.active_record` statement's text as a breadcrumb, and
  # whether a string `where("... = ?", token)` keeps the value out of that text
  # depends on the connection: with prepared statements on it travels as a bind,
  # and with them off — `unprepared_statement`, a pooler that disables them — it
  # is quoted into the statement, and a live bearer token would ship to GlitchTip
  # with the next event in the same scope. So Postgres hashes the stored value and
  # the statement carries only the digest, the same one-way fingerprint
  # AuthRecoveryCoordinator already keeps in session metadata. Safe whatever the
  # connection setting, and the compare-and-set stays one atomic UPDATE.
  #
  # @return [Boolean] whether the verdict was written
  def write_credential_verdict(values, probed_token)
    written = self.class.where(id: id)
      .where(
        "encode(sha256(convert_to(oauth_config #>> '{credentials_json,claudeAiOauth,accessToken}', 'UTF8')), 'hex') = ?",
        Digest::SHA256.hexdigest(probed_token)
      )
      .update_all(values)

    if written.zero?
      Rails.logger.info "[ClaudeAccount] Discarded a credential probe for #{email}: the stored token moved while the probe was in flight"
      return false
    end

    # The row is authoritative and already updated; this keeps an instance the
    # caller is about to render (or re-read) from disagreeing with it. Assigned
    # rather than reloaded so an UPDATE does not cost a SELECT on every sweep.
    values.each { |attribute, value| write_attribute(attribute, value) }
    clear_attribute_changes(values.keys)
    true
  end

  # See the before_save that calls this.
  def reset_credential_verdict_on_new_token
    # Codex has no non-consuming probe, so a Codex row never carries a verdict
    # and there is never one to retire.
    return if codex?
    return unless will_save_change_to_oauth_config?

    before, after = oauth_config_change_to_be_saved
    return if claude_access_token_in(before) == claude_access_token_in(after)

    self.credential_verified_at = nil
    self.credential_rejected_at = nil
    self.credential_rejection_reason = nil
  end

  # The Claude access token inside an oauth_config blob. Reads the blob passed in
  # rather than the attribute, for the same reason #refresh_token_in does: it is
  # asked about the value a save is about to replace.
  def claude_access_token_in(config)
    return nil unless config.is_a?(Hash)

    config.dig("credentials_json", "claudeAiOauth", "accessToken")
  end

  # The refresh token inside an oauth_config blob, whichever runtime owns it.
  # Reads the blob passed in rather than the attribute, so it can be asked about
  # the value a save is about to replace.
  def refresh_token_in(config)
    return nil unless config.is_a?(Hash)

    if codex?
      config.dig("auth_json", "tokens", "refresh_token")
    else
      config.dig("credentials_json", "claudeAiOauth", "refreshToken")
    end
  end

  # --- Claude token helpers ---

  # The Claude token expiration parsed from oauth_config. The expiresAt field is
  # stored in milliseconds since epoch.
  # @return [Time, nil]
  def claude_token_expires_at
    ms = oauth_config&.dig("credentials_json", "claudeAiOauth", "expiresAt")
    ms.present? ? Time.at(ms.to_f / 1000.0) : nil
  end

  # --- Codex token helpers ---

  def codex_auth_json
    oauth_config&.dig("auth_json")
  end

  def codex_tokens
    codex_auth_json&.dig("tokens")
  end

  def codex_refresh_token
    codex_tokens&.dig("refresh_token")
  end

  # When the Codex CLI last refreshed the tokens on disk, parsed from auth.json's
  # last_refresh (ISO8601). Drives the TTL-based expiry below.
  # @return [Time, nil]
  def codex_last_refresh
    raw = codex_auth_json&.dig("last_refresh")
    raw.present? ? Time.zone.parse(raw.to_s) : nil
  rescue ArgumentError, TypeError
    nil
  end

  # Codex auth.json carries no explicit access-token expiry, and the CLI
  # refreshes the active account's tokens in place at runtime. Zimmer refreshes pool
  # accounts on a soft TTL (CodexAuthProvider::TOKEN_TTL) measured from
  # last_refresh, which keeps refresh tokens warm and fires roughly once per day.
  # API-key accounts never expire.
  # @return [Time, nil]
  def codex_token_expires_at
    return nil if codex_api_key_account?

    last = codex_last_refresh
    last ? last + CodexAuthProvider::TOKEN_TTL : nil
  end

  def codex_token_expired?
    return false if codex_api_key_account?

    expires = codex_token_expires_at
    # No last_refresh recorded → treat as stale so the next sweep refreshes it.
    expires.nil? || expires <= Time.current
  end

  def codex_token_expiring_soon?(threshold)
    return false if codex_api_key_account?

    expires = codex_token_expires_at
    # No last_refresh recorded → refresh on the next sweep.
    return true if expires.nil?
    expires < threshold.from_now
  end

  # Refreshes Codex ChatGPT OAuth tokens via OpenAI's token endpoint.
  # API-key accounts have nothing to refresh and succeed as a no-op.
  #
  # @return [true] if refresh succeeded (or nothing to refresh)
  # @return [false] if refresh failed
  # @param recovery_probe [Boolean] see #refresh_token! — downgrades the expected
  #   failure log to .info when probing a known needs_reauth account.
  def refresh_codex_token!(recovery_probe: false)
    # API-key accounts authenticate statically — nothing to rotate.
    return true if codex_api_key_account?

    # The Codex CLI refreshes the active account's tokens in place during
    # sessions and OpenAI rotates the refresh_token on each use. When that
    # happens the CLI writes the new pair to ~/.codex/auth.json while Zimmer's DB
    # copy goes stale — replaying it yields refresh_token_reused. Sync the
    # filesystem tokens (identity-gated, no-op when they aren't ours) first.
    sync_codex_tokens_from_filesystem!

    refresh_tok = codex_refresh_token
    raise "Cannot refresh: missing refresh token for #{email}" unless refresh_tok.present?

    uri = URI(CodexAuthProvider::TOKEN_ENDPOINT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 10
    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate({
      client_id: CodexAuthProvider::CLIENT_ID,
      grant_type: "refresh_token",
      refresh_token: refresh_tok
    })
    response = http.request(request)

    if response.code.start_with?("2")
      token_data = JSON.parse(response.body)

      updated = oauth_config.deep_dup
      auth_json = updated["auth_json"] ||= {}
      tokens = auth_json["tokens"] ||= {}
      # Each field is rotated only when the response includes it, matching the
      # Codex CLI's persist_tokens behavior; account_id and other fields persist.
      tokens["id_token"] = token_data["id_token"] if token_data["id_token"].present?
      tokens["access_token"] = token_data["access_token"] if token_data["access_token"].present?
      tokens["refresh_token"] = token_data["refresh_token"] if token_data["refresh_token"].present?
      auth_json["last_refresh"] = Time.current.utc.iso8601

      # Same contract as the Claude branch: persist first, and never let the
      # filesystem write roll the new pair back — OpenAI has already spent the one
      # we presented, so this row is the only place the chain survives.
      update!(oauth_config: updated, stale_refresh_failures: 0, last_stale_refresh_failure_at: nil)

      if is_current?
        begin
          write_codex_auth_to_filesystem!
        rescue StandardError => e
          Rails.logger.error "[ClaudeAccount] Refreshed Codex tokens for #{email} but could not write them to the filesystem: #{e.message}"
        end
      end

      Rails.logger.info "[ClaudeAccount] Codex token refresh succeeded for #{email}"
      true
    elsif recovery_probe
      Rails.logger.info "[ClaudeAccount] Codex recovery probe for #{email} still failing (#{response.code}); awaiting re-auth"
      false
    else
      handle_refresh_rejection(response, presented: refresh_tok, kind: codex_refresh_failure_kind(response))
    end
  rescue StandardError => e
    if recovery_probe
      Rails.logger.info "[ClaudeAccount] Codex recovery probe error for #{email}: #{e.message}; awaiting re-auth"
    elsif transient_refresh_error?(e)
      # The refresh job retries transient failures with backoff and escalates
      # to .error only once retries are exhausted, so log at .info here.
      Rails.logger.info "[ClaudeAccount] Codex token refresh transient error for #{email}: #{e.class} - #{e.message} (will retry)"
    else
      Rails.logger.error "[ClaudeAccount] Codex token refresh error for #{email}: #{e.message}"
    end
    false
  end

  # OpenAI error codes that indicate the Codex credential itself is finished
  # (mirrors the Codex CLI's classify_refresh_token_failure). `refresh_token_reused`
  # is deliberately absent: it describes the value, not the credential.
  DEAD_CODEX_ERROR_CODES = %w[refresh_token_expired refresh_token_invalidated].freeze

  # OpenAI's counterpart to #claude_refresh_failure_kind. `refresh_token_reused`
  # is a spent value by definition — it says another holder of the same chain got
  # there first — while expiry and invalidation are verdicts on the credential.
  def codex_refresh_failure_kind(response)
    return :dead if response.code == "401"

    begin
      body = JSON.parse(response.body)
    rescue JSON::ParserError
      return :unknown
    end
    return :unknown unless body.is_a?(Hash)

    # Error code can appear as { "error": { "code": "..." } }, { "error": "..." },
    # or a top-level { "code": "..." }.
    error_field = body["error"]
    code =
      if error_field.is_a?(Hash)
        error_field["code"]
      elsif error_field.is_a?(String)
        error_field
      else
        body["code"]
      end

    return :stale if code == "refresh_token_reused"

    DEAD_CODEX_ERROR_CODES.include?(code) ? :dead : :unknown
  end
end
