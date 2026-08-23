# frozen_string_literal: true

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
#   :rotated            Nobody else moved the pool and this session is still on
#                       the identity that just failed. Re-injecting it would
#                       reproduce the wall, so rotate to a different account.
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
# == Why the outgoing account is probed before rotating ==
#
# "Not logged in" is the runtime's word for both "your token is dead" and "you
# are out of quota", so the text cannot tell those apart — and the whole point of
# the QUOTA_EXHAUSTED / AUTH_UNRECOVERABLE distinction is that they tell the user
# opposite things. Refreshing the outgoing account's token before rotating away
# separates them on evidence rather than on prose: a refresh that fails
# permanently marks the account needs_reauth (no reset will fix it), a refresh
# that succeeds leaves it quota_exceeded (a reset will). The pool's resulting
# shape is what #park_reason_for_pool reads.
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

  # What the coordinator decided. `account` is the identity now on disk for the
  # outcomes that resolved to one; nil for the two park outcomes.
  Plan = Data.define(:outcome, :account, :detail) do
    def resolved? = %i[adopted rotated rotation_in_flight].include?(outcome)
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
  # ClaudeAccount.any_serviceable_for?, which is also what #auth_health counts.
  # Asking it through the `status` column instead is what made this method answer
  # QUOTA_EXHAUSTED at 02:06Z on 2026-08-23 while the health check reported three
  # accounts available seven minutes later: the column had been stamped by
  # rotations that carried no quota evidence, and only the 15-minute healer ever
  # unstamps it. One predicate, so the two surfaces cannot disagree again.
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
  # is moving the pool. Re-injecting would re-spawn into the same wall, so move.
  def rotate_away_from(current, working_directory)
    classify_outgoing!(current)

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
