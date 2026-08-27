# frozen_string_literal: true

require "digest"

# Decides what a session should do the FIRST time its runtime reports
# "Not logged in · Please run /login", coordinating that decision with any
# account rotation another session may already be running and with what the pool
# is known to look like.
#
# == The failure this removes ==
#
# Zimmer had two independent exits from an exhausted or invalid account, and they
# did not talk to each other:
#
#   1. The quota path — a :quota_exceeded classification rotates to another
#      account, and parks with QUOTA_EXHAUSTED when there is nothing to rotate
#      into. Correct and informative.
#   2. The auth-recovery path — AuthRecoveryService re-injects THE CURRENT
#      ACTIVE ACCOUNT and re-spawns, up to three times.
#
# Path 2 never consulted rotation state or quota state, so when the active
# account was itself the problem, "recovery" re-wrote the identical dead
# credentials and re-spawned into the identical wall — surfacing the runtime's
# "Not logged in" text to the user on every attempt — and then parked with
# AUTH_UNRECOVERABLE ("re-authenticate an account"), which is the wrong
# instruction when the real cause is a quota window that will reset on its own.
#
# Production session 657 is the trail: at 11:46:39Z it logged "Not logged in
# detected on successful exit - attempting auth recovery" → "Auth recovery limit
# reached (3 attempts) — failing" → parked AUTH_UNRECOVERABLE for an hour; at
# 11:50:12Z it was back at "retrying 1/3", re-injecting the SAME account
# (tadas412@gmail.com). Across the whole incident the session logged not one
# "Account quota hit — rotated to …" line: the rotation path never ran, because
# the auth signature is checked before the API-error path and shadows the quota
# message that was sitting in the same transcript.
#
# == The decision tree ==
#
# Everything below happens under a pool-wide advisory lock
# (ClaudeAccount.with_pool_lock), so N sessions hitting the wall at the same
# moment take these branches one at a time rather than each starting a rotation.
#
#   :adopted            The pool moved while this session's process was holding
#                       the old identity — the account that is current now is not
#                       the one the process was spawned with. Someone else's
#                       rotation already did the work; re-inject and resume.
#                       Costs the session nothing (see AuthRecoveryService).
#   :reseeded           Under session-scoped credentials, the DB-held access
#                       token is serviceable but the process reported an auth
#                       failure. The process was holding an older token, so keep
#                       the account and hand the next process the current one.
#   :rotated            Nobody else moved the pool and the current account
#                       cannot serve. Rotate to a different account.
#   :rotation_in_flight The lock was held for longer than a rotation takes.
#                       Another process is mid-rotation and slow; do not mutate
#                       the pool underneath it. Resume and let the bounded retry
#                       budget cover the case where it never finishes.
#   :quota_exhausted    Nothing left to rotate into and at least one account is
#                       quota_exceeded — waiting genuinely helps. The caller
#                       parks with AuthOutageParkService::QUOTA_EXHAUSTED and its
#                       reset-derived retry, instead of the hour-long generic
#                       delay and the "re-authenticate" instruction.
#   :unusable           Nothing left to rotate into and nothing is merely
#                       throttled — every account needs a human to re-authenticate
#                       it. AUTH_UNRECOVERABLE, correctly this time.
#
# == Why session-scoped recovery probes the access token first ==
#
# "Not logged in" is the runtime's word for both "your token is dead" and "you
# are out of quota", so the text cannot tell those apart. Under session-scoped
# credentials, it also cannot tell "this process holds the access token from
# before another process refreshed the same account" from either one.
#
# A refresh is not a read-only probe there: Anthropic replaces the access token,
# immediately stranding every running process that was handed the prior value.
# Each spawn records a one-way fingerprint of the access-token generation it was
# actually handed. Recovery probes the stored access token through the Messages
# API first, and a clear reading is re-seeded only when that fingerprint moved
# (or is absent on one legacy process). The same generation failing twice rotates
# instead of spending the whole retry budget on an unchanged token. Only a token
# Anthropic actually refuses is refreshed, and a successful repair is re-seeded.
# Shared-file mode keeps the old refresh-before-rotation classification because
# the CLI can own a newer refresh chain on disk in that mode.
#
# This adds NO new string matching. What reaches the coordinator is decided by
# AuthRecoveryService.auth_error?, which reads the transcript entry's structured
# `error` type first and falls back to prose — because the prose has broken
# before when Claude Code changed its wording, most recently on 2026-08-20
# (see docs/src/content/docs/limitations.md).
class AuthRecoveryCoordinator
  include DatabaseRetry

  # Session metadata key recording which login identity the session's current
  # process was spawned with. Comparing it against the pool's current account is
  # what distinguishes "the pool moved under me" from "I am holding the identity
  # that failed" — the distinction the old code never made.
  IDENTITY_KEY = "auth_identity_email"
  IDENTITY_AT_KEY = "auth_identity_recorded_at"
  CREDENTIAL_MODE_KEY = "auth_session_scoped_credentials"
  CREDENTIAL_FINGERPRINT_KEY = "auth_access_token_fingerprint"
  SESSION_SCOPED_SETTING_KEY = "session_scoped_credentials"

  # What the coordinator decided. `account` is the identity selected for the
  # next spawn for outcomes that resolved to one; nil for the two park outcomes.
  Plan = Data.define(:outcome, :account, :detail) do
    def resolved? = %i[adopted reseeded rotated rotation_in_flight].include?(outcome)
    def park? = %i[quota_exhausted unusable].include?(outcome)

    # An adoption is somebody else's rotation doing this session a favour. It is
    # not an attempt this session made, so it must not spend the session's
    # bounded recovery budget — otherwise a long-running session that legitimately
    # rides out several rotations gets parked for other sessions' activity.
    def consumes_budget? = outcome != :adopted
  end

  attr_reader :session

  def initialize(session, auth_provider: nil, logger: nil, lock_wait: ClaudeAccount::POOL_LOCK_WAIT)
    @session = session
    @auth_provider = auth_provider
    @lock_wait = lock_wait
    @logger = logger || StructuredLogger.new({ session_id: session&.id, service: "AuthRecoveryCoordinator" })
  end

  # Record the identity a session's process is being spawned with. Called from
  # every path that writes credentials for a specific session, so the next
  # "Not logged in" can tell an adoption from a rotation.
  #
  # @param session [Session, nil] nil on the boot warm-up path, which has no session
  # @param account [#email, nil]
  def self.record_identity!(session, account)
    return unless session && account.respond_to?(:email) && account.email.present?

    session.update!(
      metadata: (session.metadata || {}).merge(
        IDENTITY_KEY => account.email,
        IDENTITY_AT_KEY => Time.current.iso8601
      )
    )
  rescue => e
    # Best effort: a missing marker degrades one recovery decision to "rotate",
    # which is still strictly better than the old "re-inject the same thing".
    Rails.logger.info "[AuthRecoveryCoordinator] Could not record auth identity: #{e.message}"
  end

  # Record what the child process is ACTUALLY about to receive, at the spawn-env
  # seam where fail-open fallback has already decided between the shared file and
  # a session-scoped access token. The global setting can change while a process
  # is alive, so recovery must not infer the failed process's mode from its value
  # later. The fingerprint is one-way and exists only to answer whether the DB
  # token generation changed since this process was spawned.
  def self.record_spawn_credentials!(session_id:, account:, session_scoped:)
    session = Session.find_by(id: session_id)
    return unless session

    updates = {
      CREDENTIAL_MODE_KEY => !!session_scoped,
      CREDENTIAL_FINGERPRINT_KEY => session_scoped ? credential_fingerprint(account) : nil
    }
    if account.respond_to?(:email) && account.email.present?
      updates[IDENTITY_KEY] = account.email
      updates[IDENTITY_AT_KEY] = Time.current.iso8601
    end

    session.update!(metadata: (session.metadata || {}).merge(updates))
  rescue => e
    Rails.logger.info "[AuthRecoveryCoordinator] Could not record spawn credentials: #{e.message}"
  end

  def self.credential_fingerprint(account)
    token = account&.claude_access_token
    token.present? ? Digest::SHA256.hexdigest(token) : nil
  end

  # Resolve this session's dead on-disk identity against the pool.
  #
  # @param working_directory [String, nil]
  # @return [Plan]
  def resolve!(working_directory)
    # Wrapped in an array so "the block returned nil" and "the lock was never
    # acquired" stay distinguishable — with_pool_lock signals the latter with nil.
    held = ClaudeAccount.with_pool_lock(runtime, wait: @lock_wait) { [ decide(working_directory) ] }
    return held.first if held

    # The lock outlived POOL_LOCK_WAIT. Another process is mid-rotation, so the
    # one thing we must not do is start a second one — it would burn the account
    # that rotation is in the middle of activating. Its credential write is also
    # already in progress, so re-spawning against whatever lands on disk is the
    # best available move.
    @logger.warn("Pool lock held past the wait — treating as a rotation in flight")
    Plan.new(outcome: :rotation_in_flight, account: nil, detail: "another session's account rotation is still running")
  end

  # The park reason the pool's CURRENT shape justifies. Used both for the two
  # park outcomes above and by ProcessLifecycleManager when the retry budget runs
  # out, so a budget exhaustion that happens to coincide with a drained pool
  # still tells the user "wait for reset" rather than "go re-authenticate".
  #
  # "Has the pool got anything left" is asked through
  # ClaudeAccount.any_serviceable_for?, the same predicate #auth_health counts —
  # so a park and the health card cannot describe different pools. Asking it
  # through the `status` column instead answers on labels that only the
  # 15-minute healer ever clears, which is how a park and a health check minutes
  # apart came to contradict each other; see [One predicate for "is the pool
  # drained"] in docs/auth/harness.md.
  #
  # @return [String] an AuthOutageParkService reason
  def park_reason_for_pool
    return AuthOutageParkService::AUTH_UNRECOVERABLE if ClaudeAccount.any_serviceable_for?(runtime)
    return AuthOutageParkService::QUOTA_EXHAUSTED if pool.quota_exceeded.exists?

    AuthOutageParkService::AUTH_UNRECOVERABLE
  end

  private

  def auth_provider
    @auth_provider ||= RuntimeAuthProvider.for(runtime)
  end

  def runtime
    session&.agent_runtime
  end

  def pool
    auth_provider.accounts
  end

  # Runs with the pool lock held.
  def decide(working_directory)
    current = auth_provider.current_account

    # Nothing is current: there is no identity to diagnose, only one to establish.
    # inject_for_session! bootstraps from the pool (or the filesystem) if it can.
    return adopt_or_park(working_directory, "no account was current") if current.nil?

    spawned_as = session&.metadata&.dig(IDENTITY_KEY)
    if spawned_as.present? && spawned_as != current.email
      return adopt_or_park(
        working_directory,
        "the pool rotated from #{spawned_as} to #{current.email} while this session was running"
      )
    end

    rotate_away_from(current, working_directory)
  end

  # The pool already holds a different identity than the one this session's
  # process died holding. Take it; do not rotate again.
  def adopt_or_park(working_directory, detail)
    account = inject(working_directory)
    # inject swallows filesystem/IO failures into nil, so "no account" here does
    # not always mean "no account in the pool". Say which, or the park message
    # tells the user to re-authenticate over what is really a disk problem.
    return park_plan(injection_failed: ClaudeAccount.any_serviceable_for?(runtime)) unless account

    self.class.record_identity!(session, account)
    @logger.info("Adopted the pool's current identity", account: account.email, detail: detail)
    Plan.new(outcome: :adopted, account: account, detail: detail)
  end

  # This session is still holding the identity that just failed, and nobody else
  # is moving the pool. With isolated access tokens the process may simply be
  # holding the value from before another refresh, so prove whether the DB token
  # can serve before deciding that the account itself must move.
  def rotate_away_from(current, working_directory)
    if session_scoped_claude?
      plan = reseed_serviceable_current(current, working_directory)
      return plan if plan
    else
      classify_outgoing!(current)
    end

    result = auth_provider.rotate_for_quota!(
      triggered_by: session ? "session:#{session.id}" : nil,
      reason: "auth_recovery",
      expected_current_email: current.email
    )

    unless result[:success]
      # A rotation that lost the lock race is not an exhausted pool — the holder
      # is mid-rotation and about to write good credentials. Wait for it rather
      # than parking a session whose pool is fine.
      if result[:reason] == "rotation_in_flight"
        return Plan.new(outcome: :rotation_in_flight, account: nil,
          detail: "another session's account rotation is still running")
      end

      @logger.warn("No account to rotate into during auth recovery", from: current.email, reason: result[:reason])
      return park_plan
    end

    account = inject(working_directory) || result[:account]
    self.class.record_identity!(session, account)
    @logger.warn("Rotated away from the identity the runtime rejected",
      from: current.email, to: account.email)

    Plan.new(
      outcome: :rotated,
      account: account,
      detail: "rotated from #{current.email} to #{account.email}"
    )
  end

  # A session-scoped Claude process receives one access-token VALUE at spawn.
  # Refreshing the account later replaces that value in the DB, but cannot update
  # the environment of an already-running process. Its next request then reports
  # "Not logged in" even while the DB-held token and the account's quota are both
  # healthy. The non-consuming Messages API probe distinguishes that stale child
  # from a bad account without rotating the credential chain again.
  #
  # Returns a :reseeded plan when the current account can serve, otherwise nil so
  # the ordinary rotation/park path handles live quota exhaustion or a credential
  # that could not be repaired.
  def reseed_serviceable_current(current, working_directory)
    probe = probe_access_token(current)
    repaired = false

    if access_token_refused?(probe) && current.can_refresh_token?
      @logger.info("Stored access token was refused — refreshing once before rotating",
        account: current.email)
      refresh = auth_provider.refresh!(current)
      return nil unless refresh.ok?

      repaired = true
      current.reload
      probe = probe_access_token(current)
    end

    if probe.success?
      snapshot = QuotaSnapshotService.save_snapshot(current, probe, trigger: "auth_recovery")
      unless snapshot.windows_clear?
        # Preserve this definitive result before AccountRotationService performs
        # its own best-effort outgoing probe. If that second request is
        # unreachable, the already-saved five-hour-cap evidence must still make
        # the account ineligible and make an exhausted pool park for quota.
        current.mark_quota_exceeded! unless current.quota_exceeded?
        return nil
      end

      # The display already derives this answer from the reading, but account
      # selection reads the sticky status column. Converge it before #inject so
      # the same account the probe just proved healthy is not skipped as stale.
      current.update!(status: :active) if current.quota_exceeded?
    elsif !probe.unreachable?
      return nil
    end

    # A healthy DB token only proves the failed child was stale when its token
    # generation differs. A legacy child has no fingerprint, so allow one reseed;
    # the replacement records one at the actual spawn seam. If that same value
    # fails again, rotate instead of spending the whole retry budget reusing it.
    return nil unless repaired || spawned_token_stale?(current)
    return nil unless current.active?

    account = inject(working_directory)
    return park_plan(injection_failed: true) unless account

    if account.id != current.id
      self.class.record_identity!(session, account)
      @logger.warn("Credential injection selected a different identity after the probe",
        from: current.email, to: account.email)
      return Plan.new(
        outcome: :rotated,
        account: account,
        detail: "selected #{account.email} after #{current.email} stopped being eligible during recovery"
      )
    end

    self.class.record_identity!(session, account)
    detail = if repaired
      "refreshed the rejected access token and re-seeded #{account.email}"
    elsif probe.unreachable?
      "kept #{account.email} because the access-token probe was inconclusive and re-seeded it without rotating"
    else
      "proved #{account.email} still has a valid access token and quota, then re-seeded it"
    end

    @logger.info("Re-seeded the current session-scoped identity", account: account.email, repaired: repaired)
    Plan.new(outcome: :reseeded, account: account, detail: detail)
  rescue => e
    # A probe failure must not bypass recovery altogether. Falling through to
    # rotation preserves the prior bounded behaviour while the error remains
    # visible in structured logs.
    @logger.info("Could not probe the session-scoped access token before recovery", error: e.message)
    nil
  end

  def probe_access_token(account)
    QuotaCheckService.check_with_token(account.claude_access_token)
  end

  def access_token_refused?(probe)
    !probe.success? && !probe.unreachable?
  end

  def session_scoped_claude?
    return false unless runtime.to_s == ClaudeAuthProvider::RUNTIME

    spawned_session_scoped? || AppSetting.session_scoped_credentials_enabled?
  end

  def spawned_session_scoped?
    metadata = session&.metadata || {}
    return metadata[CREDENTIAL_MODE_KEY] if metadata.key?(CREDENTIAL_MODE_KEY)

    flag = session&.session_experimental_flags&.find_by(setting_key: SESSION_SCOPED_SETTING_KEY)
    flag&.value_at_end == true
  end

  def spawned_token_stale?(current)
    spawned = session&.metadata&.dig(CREDENTIAL_FINGERPRINT_KEY)
    current_fingerprint = self.class.credential_fingerprint(current)
    spawned.blank? || (current_fingerprint.present? && spawned != current_fingerprint)
  end

  # Refresh the outgoing account's token so the status it is about to be parked
  # with reflects why it stopped working. A permanent OAuth failure marks it
  # needs_reauth (refresh_token! does this), which rotate! then leaves alone; a
  # successful or merely transient refresh leaves it to be marked quota_exceeded.
  # Best effort — a network blip must not block the rotation.
  def classify_outgoing!(account)
    result = auth_provider.refresh!(account)
    return if result.ok?

    # A lost single-use-token race no longer reaches here as :needs_reauth.
    # ClaudeAccount#refresh_token! serializes on the row and, before condemning
    # anything, checks whether the token it presented has since moved; and a
    # rejection it cannot attribute to a dead credential collects a strike rather
    # than a verdict. So a :needs_reauth at this point is a real one, and a
    # rejected-but-unproven value arrives as :stale.
    if result.error == :needs_reauth
      @logger.warn("Outgoing account's credentials are permanently invalid", account: account.email)
    else
      @logger.info("Outgoing account's token refresh failed transiently", account: account.email)
    end
  rescue => e
    @logger.info("Could not classify the outgoing account before rotating", error: e.message)
  end

  def inject(working_directory)
    auth_provider.inject_for_session!(session, working_directory)
  rescue => e
    @logger.error("Identity injection raised during auth recovery", error: e.message)
    nil
  end

  def park_plan(injection_failed: false)
    reason = park_reason_for_pool
    if reason == AuthOutageParkService::QUOTA_EXHAUSTED
      Plan.new(
        outcome: :quota_exhausted,
        account: nil,
        detail: "every account in the pool is over its quota"
      )
    else
      detail = if injection_failed
        "the pool has a usable account but its credentials could not be written to disk"
      else
        "no account in the pool has usable credentials"
      end

      Plan.new(outcome: :unusable, account: nil, detail: detail)
    end
  end
end
