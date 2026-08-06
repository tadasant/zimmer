# frozen_string_literal: true

require "automated_prompts"

# Parks a session that cannot make progress because the runtime's login pool has
# nothing usable left, and schedules it to wake up and try again once the outage
# plausibly clears.
#
# == When this fires ==
#
# Two exit decisions in ProcessLifecycleManager mean "we are out of runway":
#
#   1. :quota_exceeded with no rotation target — every account in the pool is
#      quota_exceeded, so AccountRotationService#rotate! returns
#      { success: false, reason: "no_available_accounts" }.
#   2. Auth recovery that cannot succeed — the CLI reports
#      "Not logged in · Please run /login" and re-injecting credentials does not
#      fix it (either no account is available at all, or the injected identity is
#      rejected again on every attempt).
#
# Neither is a state a bare `needs_input` communicates. The only visible artifact
# would be the CLI's own "Not logged in · Please run /login" text, which says
# nothing about the cause, notifies nobody, and leaves the session stopped even
# after the condition clears.
#
# == What parking does ==
#
# 1. Writes an unmistakable session log naming the outage and the retry time.
# 2. Sends a push notification so the user learns about it away from the UI.
# 3. Records the outage on the session (`auth_outage_*` metadata).
# 4. Creates a one-time wake-up trigger at the retry time. Creating that trigger
#    is what puts the session to sleep — Trigger's after_create callback sets
#    `pending_sleep` on a still-running session, and the pause callback
#    transitions it needs_input → waiting. A `waiting` session is dormant: the
#    heartbeat sweep anchors its cadence instead of nudging it, so a parked
#    session cannot be re-poked into the same wall.
#
# QuotaResetCheckerJob calls .wake_parked_sessions! after it restores accounts,
# so a session usually resumes as soon as the pool recovers rather than waiting
# out the full timer. Both park reasons get that fast path, on different
# evidence — see .wake_parked_sessions!. The trigger is the backstop for the
# case where nothing observable changes (no snapshot, a runtime with no quota
# API, or an outage that heals on Anthropic's side without touching an account).
class AuthOutageParkService
  include DatabaseRetry

  # Why the session was parked. The value is stored verbatim in
  # `metadata["auth_outage_reason"]`.
  QUOTA_EXHAUSTED = "quota_exhausted"
  AUTH_UNRECOVERABLE = "auth_unrecoverable"
  REASONS = [ QUOTA_EXHAUSTED, AUTH_UNRECOVERABLE ].freeze

  # Metadata keys written by #park!, cleared when the session resumes.
  OUTAGE_METADATA_KEYS = %w[
    auth_outage_reason
    auth_outage_parked_at
    auth_outage_retry_at
    auth_outage_pool_fingerprint
  ].freeze

  # Identity fingerprint of the runtime's usable accounts at the moment of the
  # park. Comparing it against the pool's fingerprint now is what tells an
  # AUTH_UNRECOVERABLE park whether anything has actually changed since the
  # credentials that failed it. See .wake_parked_sessions!.
  POOL_FINGERPRINT_KEY = "auth_outage_pool_fingerprint"

  # How many times the sweep may wake one session early on an
  # AUTH_UNRECOVERABLE park before it stops trying and leaves it to the timer.
  #
  # Deliberately NOT in OUTAGE_METADATA_KEYS: the counter has to survive the
  # resume it authorises, or a session whose identity problem is its own rather
  # than the pool's would earn a fresh budget on every re-park and spin for as
  # long as the pool keeps changing underneath it.
  EARLY_WAKE_COUNT_KEY = "auth_outage_early_wakes"
  MAX_EARLY_WAKES = 3

  # Fallback wait when no reset time is known — an auth outage has no published
  # clock, and Anthropic's 5-hour quota window means an hour is a reasonable
  # first probe even when snapshots are missing.
  DEFAULT_RETRY_DELAY = 1.hour

  # Floor and ceiling on the computed retry. The floor keeps a reset timestamp
  # that has just passed (or is seconds away) from producing a wake-up the
  # trigger scheduler would treat as past-dated; the ceiling keeps a bogus
  # far-future reset (e.g. a sentinel expiry) from parking a session for days.
  MIN_RETRY_DELAY = 5.minutes
  MAX_RETRY_DELAY = 12.hours

  # Added to a known reset time so the wake-up lands after the window has
  # actually turned over, and after QuotaResetCheckerJob's 15-minute sweep has
  # had a chance to flip the accounts back to active.
  RESET_BUFFER = 2.minutes

  attr_reader :session, :log_buffer

  def initialize(session, log_buffer: nil, logger: nil)
    @session = session
    @log_buffer = log_buffer
    @logger = logger || StructuredLogger.new({ session_id: session&.id, service: "AuthOutageParkService" })
  end

  # Park the session and schedule its retry.
  #
  # @param reason [String] one of REASONS
  # @param detail [String, nil] extra context appended to the log line (e.g. the
  #   quota message from the transcript)
  # @return [Time, nil] the scheduled retry time, or nil if parking failed
  def park!(reason:, detail: nil)
    raise ArgumentError, "unknown park reason: #{reason}" unless REASONS.include?(reason)
    return nil unless session

    retry_at = compute_retry_at(reason)

    # Schedule the retry BEFORE recording it. The metadata is what renders the
    # banner promising "will resume automatically at HH:MM", so writing it first
    # and then failing to create the trigger would leave the user with a promise
    # nothing can keep.
    trigger = schedule_wake!(reason, retry_at)

    add_log(park_message(reason, retry_at, detail), level: "error")
    log_buffer&.flush

    record_outage!(reason, retry_at)
    notify!(reason, retry_at)

    @logger.warn("Session parked for auth outage",
      reason: reason, retry_at: retry_at.utc.iso8601, trigger_id: trigger&.id)

    retry_at
  rescue ArgumentError
    # A bad reason is a programmer error, not an outage — don't swallow it.
    raise
  rescue => e
    # Parking is a best-effort improvement on top of the exit decision the
    # caller has already made. If it fails, the session still lands in
    # needs_input — it just doesn't auto-retry.
    @logger.error("Failed to park session for auth outage", reason: reason, error: e.message)
    nil
  end

  # Resume every parked session whose runtime can plausibly serve it again.
  # Called by QuotaResetCheckerJob right after it restores quota_exceeded
  # accounts to active, so the accounts and the sessions blocked on them recover
  # together instead of the sessions waiting out a timer for a condition that
  # has already cleared.
  #
  # == The two reasons need different evidence ==
  #
  # "An account is available again" is the whole story for a QUOTA_EXHAUSTED
  # park: the pool was empty, now it is not, go.
  #
  # It is no evidence at all for an AUTH_UNRECOVERABLE park. That reason is
  # reached precisely when an account WAS available and the runtime rejected its
  # credentials anyway — AuthRecoveryCoordinator#park_reason_for_pool picks it
  # when `pool.available.exists?` — so "an available account exists" is true by
  # construction at park time. Waking on it alone would resume the session into
  # the identical failure every 15 minutes forever.
  #
  # The evidence an auth park actually needs is that the pool's *identities*
  # changed since it was parked: an account added, removed, restored to active,
  # or re-authenticated. That is what POOL_FINGERPRINT_KEY records at park time
  # and what .pool_fingerprint answers for now, and it is exactly the set of
  # events that can turn a rejected identity into a working one. No change, no
  # wake — the session keeps its timer, which is what it had before.
  #
  # A changed fingerprint is evidence, not proof: a session whose credentials
  # fail for a reason of its own rather than the pool's would pass the guard
  # every time an unrelated account rotated its token, so MAX_EARLY_WAKES caps
  # how many of these a single session may consume. Past the cap it falls back
  # to the timer, which is the behaviour it had before this fast path existed.
  #
  # An outage that heals on the vendor's side without touching any account row
  # is not visible to this sweep and still waits out its timer. That backstop is
  # why the trigger exists.
  #
  # @return [Integer] number of sessions resumed
  def self.wake_parked_sessions!(logger: nil)
    logger ||= StructuredLogger.new({ service: "AuthOutageParkService" })
    resumed = 0

    parked_sessions.find_each do |session|
      reason = session.metadata&.dig("auth_outage_reason")
      next unless runtime_has_available_account?(session.agent_runtime)
      next if reason == AUTH_UNRECOVERABLE && !auth_park_wakeable?(session, logger)

      if resume_parked!(session, logger)
        resumed += 1
        consume_early_wake!(session, logger) if reason == AUTH_UNRECOVERABLE
      end
    end

    resumed
  end

  # Has anything changed for an AUTH_UNRECOVERABLE park since it was parked, and
  # does it still have early-wake budget left?
  def self.auth_park_wakeable?(session, logger)
    parked_fingerprint = session.metadata&.dig(POOL_FINGERPRINT_KEY)
    # Parked before the fingerprint was recorded (an older park, or one whose
    # fingerprint could not be computed). There is nothing to compare against,
    # and "wake anyway" is the resume loop, so the timer remains its way back.
    return false if parked_fingerprint.blank?

    current = pool_fingerprint(session.agent_runtime)
    return false if current.blank? || current == parked_fingerprint

    used = session.metadata.fetch(EARLY_WAKE_COUNT_KEY, 0).to_i
    if used >= MAX_EARLY_WAKES
      logger.info("Auth-outage park has spent its early wakes — leaving it to the timer",
        session_id: session.id, early_wakes: used)
      return false
    end

    true
  end

  # A digest of the identities that can serve this runtime right now: every
  # available account's id plus a digest of its stored credentials.
  #
  # Content-addressed on purpose. `updated_at` churns for reasons that are not
  # identity changes — a rotation stamping last_rotated_to_at, a quota_hit_count
  # bump, the 5-minute filesystem token sync rewriting an unchanged config — and
  # every one of those would read as "the pool changed" and wake the session.
  # The credential bytes move only when an account is added, removed, restored
  # to active, or has its token genuinely refreshed.
  #
  # @return [String, nil] nil if the pool could not be read at all
  def self.pool_fingerprint(runtime)
    parts = RuntimeAuthProvider.for(runtime).accounts.available.map do |account|
      "#{account.id}:#{Digest::SHA256.hexdigest(account.oauth_config.to_json)}"
    end

    Digest::SHA256.hexdigest(parts.sort.join("|"))
  rescue => e
    Rails.logger.info "[AuthOutageParkService] Could not fingerprint the #{runtime} pool: #{e.message}"
    nil
  end

  # Spend one of the session's early wakes. Written after the resume rather than
  # before it so a wake that never happened costs nothing — and on the reloaded
  # row, because resume_parked! has just rewritten the metadata (the counter
  # survives that clear; it is not a stale-retry key).
  def self.consume_early_wake!(session, logger)
    session.reload
    used = session.metadata&.dig(EARLY_WAKE_COUNT_KEY).to_i
    session.update!(metadata: (session.metadata || {}).merge(EARLY_WAKE_COUNT_KEY => used + 1))
  rescue => e
    logger.warn("Failed to record an auth-outage early wake", session_id: session.id, error: e.message)
  end

  # Sessions currently dormant because of an auth outage.
  def self.parked_sessions(reason: nil)
    scope = Session.where(status: :waiting).where("metadata->>'auth_outage_reason' IS NOT NULL")
    return scope unless reason

    scope.where("metadata->>'auth_outage_reason' = ?", reason)
  end

  def self.runtime_has_available_account?(runtime)
    RuntimeAuthProvider.for(runtime).accounts.available.exists?
  rescue => e
    Rails.logger.info "[AuthOutageParkService] Could not check accounts for runtime #{runtime}: #{e.message}"
    false
  end

  # Resume one parked session, taking the same shape as every other automated
  # resume in the app: a row lock, a re-check under it, and one transaction that
  # clears the stale retry metadata and running_job_id before transitioning.
  #
  # The lock matters because two overlapping sweeps (or a sweep racing a user
  # follow-up) would otherwise both pass the guard and enqueue a job each. The
  # transaction matters because a failure part-way must not leave the session
  # dormant with its outage metadata already cleared — it would no longer render
  # a banner, and no longer match #parked_sessions, so nothing would ever pick it
  # up again.
  #
  # `resume!` consumes the outage's pending wake-up trigger
  # (SessionStateMachine#cancel_pending_one_time_wake_triggers), so the timer
  # backstop can't fire a second time on an already-running session.
  def self.resume_parked!(session, logger)
    reason = nil

    ActiveRecord::Base.transaction do
      session.lock!
      raise ActiveRecord::Rollback unless session.waiting? && session.may_resume?

      reason = session.metadata&.dig("auth_outage_reason")
      raise ActiveRecord::Rollback if reason.blank?

      session.update!(
        running_job_id: nil,
        metadata: (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)
      )
      session.resume!
    end

    return false if reason.blank? || !session.reload.running?

    session.logs.create!(level: "warning", content: resume_message(reason))
    AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)
    logger.info("Resumed session parked for auth outage", session_id: session.id, reason: reason)
    true
  rescue => e
    logger.warn("Failed to resume parked session", session_id: session.id, error: e.message)
    false
  end

  # What the user reads in the session log when the sweep resumes them. The two
  # reasons resumed on different evidence, so they say different things: a quota
  # park waited for the pool to refill, an auth park waited for the identities in
  # it to change.
  def self.resume_message(reason)
    if reason == AUTH_UNRECOVERABLE
      "The login pool changed since this session was parked (auth unrecoverable) — " \
        "resuming automatically to try the new credentials."
    else
      "Login pool recovered (#{reason.tr('_', ' ')}) — resuming this session automatically."
    end
  end

  private

  # When can this session plausibly succeed again?
  #
  # For a quota outage the answer is knowable: each quota_exceeded account's
  # latest snapshot carries reset_5h / reset_7d. QuotaResetCheckerJob considers
  # an account clear only when BOTH windows are clear, so an account frees up at
  # the LATER of its two future resets; the pool frees up at the EARLIEST such
  # account time. An auth outage has no published clock, so it falls back to the
  # default delay.
  def compute_retry_at(reason)
    known = (reason == QUOTA_EXHAUSTED) ? earliest_pool_reset : nil
    target = known ? known + RESET_BUFFER : DEFAULT_RETRY_DELAY.from_now

    target.clamp(MIN_RETRY_DELAY.from_now, MAX_RETRY_DELAY.from_now)
  end

  def earliest_pool_reset
    accounts = ClaudeAccount.quota_exceeded.for_runtime(session.agent_runtime).to_a
    return nil if accounts.empty?

    per_account = accounts.filter_map do |account|
      snapshot = account.latest_snapshot
      next unless snapshot

      # An account whose resets are both in the past is the one the next
      # QuotaResetCheckerJob tick will restore, so it clears at "now" — dropping
      # it would compute the retry from some other account hours out.
      [ snapshot.reset_5h, snapshot.reset_7d ].compact.select { |t| t > Time.current }.max || Time.current
    end

    per_account.min
  rescue => e
    @logger.info("Could not derive quota reset time from snapshots", error: e.message)
    nil
  end

  def record_outage!(reason, retry_at)
    outage = {
      "auth_outage_reason" => reason,
      "auth_outage_parked_at" => Time.current.iso8601,
      "auth_outage_retry_at" => retry_at.utc.iso8601
    }

    # The pool that just failed this session. wake_parked_sessions! wakes an
    # AUTH_UNRECOVERABLE park only once this stops describing the pool. Omitted
    # rather than written as nil when the pool cannot be read: an absent
    # fingerprint means "nothing to compare against", which the sweep reads as
    # "leave this one to its timer".
    fingerprint = self.class.pool_fingerprint(session.agent_runtime)
    outage[POOL_FINGERPRINT_KEY] = fingerprint if fingerprint.present?

    with_db_retry do
      # Reload first: schedule_wake! ran Trigger's auto-sleep callback, which
      # wrote pending_sleep straight to the row. Merging into the in-memory copy
      # would clobber it — and pending_sleep is the whole mechanism by which a
      # parked session actually goes dormant.
      session.reload
      session.update!(metadata: (session.metadata || {}).merge(outage))
    end
  end

  # Reuses the same one-time-schedule trigger shape as the wake_me_up_later MCP
  # tool: `reuse_session` + `last_session_id` means firing resumes THIS session
  # rather than spawning a new one, and Trigger#sleep_target_session_if_applicable
  # is what actually puts the session to sleep.
  def schedule_wake!(reason, retry_at)
    scheduled_at = retry_at.utc.strftime("%Y-%m-%dT%H:%M:%S")

    Trigger.create!(
      name: "Auth outage retry for session ##{session.id} at #{scheduled_at}Z",
      agent_root_name: session.agent_root_key.presence || session.agent_runtime,
      prompt_template: wake_prompt(reason),
      reuse_session: true,
      last_session_id: session.id,
      trigger_conditions_attributes: [
        {
          condition_type: "schedule",
          configuration: { "scheduled_at" => scheduled_at, "timezone" => "UTC" }
        }
      ]
    )
  end

  def notify!(reason, retry_at)
    SendPushNotificationJob.perform_later(
      session.id,
      :custom_message,
      "#{headline(reason)} Session ##{session.id} is parked and will retry automatically at #{retry_at.utc.strftime('%H:%M')} UTC."
    )
  rescue => e
    @logger.info("Failed to enqueue auth outage push notification", error: e.message)
  end

  def headline(reason)
    case reason
    when QUOTA_EXHAUSTED then "Quota exceeded across all #{runtime_label} accounts."
    else "No usable #{runtime_label} login available."
    end
  end

  def runtime_label
    RuntimeRegistry.label_for(session.agent_runtime)
  end

  def park_message(reason, retry_at, detail)
    action = case reason
    when QUOTA_EXHAUSTED
      "Every account in the pool is quota_exceeded, so there is nothing to rotate into."
    else
      "The runtime reported \"Not logged in\" and re-injecting credentials did not fix it."
    end

    [
      headline(reason),
      action,
      "This session is parked (waiting) and will resume automatically at #{retry_at.utc.iso8601} — " \
        "sooner if the pool recovers first. No further retries will run until then.",
      detail.presence
    ].compact.join(" ")
  end

  def wake_prompt(reason)
    <<~PROMPT.strip
      [AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]

      Zimmer parked this session because #{headline(reason).downcase.chomp('.')}. That window should have cleared by now, so the session is being resumed automatically.

      If you were in the middle of a task, please continue where you left off.

      If you had completed your work and were waiting for human input, please wait - the human will respond when ready.
    PROMPT
  end

  def add_log(content, level: "info")
    if log_buffer
      log_buffer.add(content, level: level)
    else
      with_db_retry { session.logs.create!(content: content, level: level) }
    end
  end
end
