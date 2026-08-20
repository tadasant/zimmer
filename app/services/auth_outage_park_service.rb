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
# 4. Creates a one-time wake-up trigger at the retry time, replacing the one the
#    session's previous park left behind. Creating that trigger is what puts the
#    session to sleep — Trigger's after_create callback sets `pending_sleep` on a
#    still-running session, and the pause callback transitions it needs_input →
#    waiting. A `waiting` session is dormant: the heartbeat sweep anchors its
#    cadence instead of nudging it, so a parked session cannot be re-poked into
#    the same wall.
#
# == One outage, one queue ==
#
# Everything a park knows is a fact about the POOL — the earliest account reset,
# whether an account is available again — and one outage hands that same fact to
# every session it stops, seconds apart. So the population has to be spread on
# both of the paths that wake it: RETRY_JITTER and the backoff floor spread the
# TIMER, and MAX_WAKES_PER_SWEEP holds .wake_parked_sessions! — which wakes on a
# pool-wide predicate, not a per-session one — to a batch.
#
# And the trigger a park creates is destroyed when it stops being useful, rather
# than left enabled for the twelve hours until its own scheduled_at lapses. See
# .discard_retry_triggers!.
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

  # Timestamps of the sweep-driven wakes an AUTH_UNRECOVERABLE park has spent,
  # and the rolling window they are counted over: at most MAX_EARLY_WAKES in any
  # EARLY_WAKE_WINDOW.
  #
  # Deliberately NOT in OUTAGE_METADATA_KEYS. The log has to survive the resume
  # it authorises, or a session whose identity problem is its own rather than the
  # pool's would earn a fresh budget on every re-park and the cap would bound
  # nothing. A rolling window rather than a lifetime count because the budget is
  # spent by successful recoveries too, and a session that recovered three times
  # over three days has earned nothing to be punished for. The window is what
  # keeps the bound meaningful: the timer alone would wake a parked session
  # ~6 times in 6 hours, so 3 early wakes on top is a bounded multiple of the
  # spawn rate the session already had, not an open loop.
  EARLY_WAKE_LOG_KEY = "auth_outage_early_wakes"
  MAX_EARLY_WAKES = 3
  EARLY_WAKE_WINDOW = 6.hours

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

  # Consecutive quota parks a session has spent, and the rolling window they are
  # counted over.
  #
  # A quota park's retry time is only as good as the pool's estimate of when it
  # will recover, and that estimate can be wrong in the one direction that hurts:
  # too soon. When it is, the session wakes into the same exhausted pool, parks
  # again on the same estimate, and repeats — and each turn of that loop costs an
  # AgentSessionJob on the 16-thread `agents` queue, a SendPushNotificationJob on
  # the 4-thread `default` queue, and a Trigger. One session doing this is noise;
  # the whole parked population doing it in lockstep, because one outage parked
  # them all within seconds of each other, is a queue backlog.
  #
  # So each consecutive park inside the window doubles the floor under the retry:
  # 5m, 10m, 20m, 40m, and on up to MAX_RETRY_DELAY. A pool that really is about
  # to recover still gets its fast first retry; one that is not stops being
  # probed every five minutes by every session at once.
  #
  # Deliberately NOT in OUTAGE_METADATA_KEYS, for the same reason
  # EARLY_WAKE_LOG_KEY is not: the log has to survive the resume it throttles, or
  # every park would start from a clean slate and the backoff would bound nothing.
  QUOTA_PARK_LOG_KEY = "auth_outage_quota_parks"
  QUOTA_PARK_WINDOW = 6.hours
  MAX_QUOTA_PARK_BACKOFF_STEPS = 6

  # Sessions parked by a single outage are parked within seconds of each other
  # and, without this, compute retry times within seconds of each other — so they
  # wake as a herd onto a queue sized for 16 concurrent agents. A bounded random
  # offset spreads the wake-ups across a few minutes, which costs no session
  # anything it would notice and costs the queue the difference between a spike
  # and a ramp.
  RETRY_JITTER = 3.minutes

  # How many parked sessions one sweep may resume.
  #
  # The jitter above spreads the TIMER. It does nothing for the other way a
  # parked session wakes: .wake_parked_sessions! resumes on "the pool has an
  # available account again", which becomes true for every session parked on that
  # pool in the same instant, and resumed every one of them in one pass. One
  # restored account therefore put the whole population back on a pool with one
  # account in it, which they re-drained in seconds and re-parked together.
  #
  # A batch instead. The throttle closes its own loop: the next sweep is 15
  # minutes away and re-reads the pool, so if the batch that went first drained
  # it again, nobody else is woken. Held sessions lose nothing — each still
  # carries its own timer, and each leads the next sweep's queue.
  MAX_WAKES_PER_SWEEP = 5

  # Prefix of the wake-up trigger's name. The park path writes it and the
  # supersede path matches on it, so they cannot drift into a state where a new
  # park stops recognising the trigger its predecessor left behind.
  RETRY_TRIGGER_NAME_PREFIX = "Auth outage retry for session"

  # What the park log says when the stop was a turn that never reached the runtime,
  # rather than a quota error the runtime itself reported.
  UNDELIVERED_TURN_DETAIL =
    "the turn was never delivered to the runtime and the login pool is still empty"

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

  # A session that stops with its turn still undelivered, while its runtime's login pool
  # has nothing left to serve it, has not finished anything — it has hit the outage. Park
  # it into `waiting` with a scheduled retry instead of letting the caller pause it onto
  # the human's action queue.
  #
  # This is the guard the resume-failure and turn-completion exit paths were missing. They
  # answer "the process is gone" with `pause!`, which is right for a turn that ran and
  # ended and wrong for one that never started: the session lands in needs_input claiming
  # to want a human, while the prompt Zimmer meant to deliver sits unconsumed in metadata
  # and the pool it was blocked on is still empty.
  #
  # Two conditions, both required, because parking a session that genuinely finished would
  # be its own bug — it would sleep, wake on a reset, and nudge an agent that had nothing
  # left to do:
  #
  #   * `active_follow_up_prompt` is still set. AgentSessionJob writes it while handing a
  #     turn to the runtime and REMOVES it on the clean-completion path, so its presence
  #     at stop time is the durable evidence that this turn never ran.
  #   * the runtime's pool has no available account — the same predicate
  #     .wake_parked_sessions! resumes on, so a session parked here is woken by exactly the
  #     evidence that would have let it run.
  #
  # The caller still performs its own `pause!`. #park! schedules the wake trigger, whose
  # after_create marks the running session `pending_sleep`, and the pause callback is what
  # carries it needs_input → waiting. So: park first, pause second.
  #
  # @param session [Session, nil]
  # @return [Boolean] true when the session was parked, and the caller must not also mark
  #   this stop as a recovery-continuable pause
  def self.park_undelivered_turn!(session, log_buffer: nil, logger: nil, detail: nil)
    return false unless session
    return false if session.metadata&.dig("active_follow_up_prompt").blank?
    return false if runtime_has_available_account?(session.agent_runtime)

    new(session, log_buffer: log_buffer, logger: logger)
      .park!(reason: QUOTA_EXHAUSTED, detail: detail || UNDELIVERED_TURN_DETAIL)
      .present?
  rescue => e
    # Same posture as #park!: this is an improvement on top of the exit decision the
    # caller already made, never a reason that decision cannot be carried out.
    Rails.logger.warn "[AuthOutageParkService] Could not park undelivered turn for session " \
      "#{session&.id} (#{e.class}): #{e.message}"
    false
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
  # It is no evidence at all for an AUTH_UNRECOVERABLE park. That reason is what
  # AuthRecoveryCoordinator#park_reason_for_pool answers whenever the pool has
  # something available and the runtime rejected it anyway (and as the fallback
  # when the pool is empty or unreadable), so for the common case "an available
  # account exists" is true by construction at park time. Waking on it alone
  # would resume the session into the identical failure every 15 minutes forever.
  #
  # The evidence an auth park needs is that the pool's *credentials* changed
  # since it was parked: an account added, removed, restored to active, or
  # re-authenticated. That is what POOL_FINGERPRINT_KEY records at park time and
  # what .pool_fingerprint answers for now, and it covers the whole set of events
  # that can turn a rejected identity into a working one. No change, no wake —
  # the session keeps its timer, which is what it had before.
  #
  # It is a coarse signal, not a repair detector. The same digest also moves when
  # RefreshRuntimeAuthTokensJob's 5-minute sync adopts a token the CLI rotated on
  # disk for the current account, which says nothing about a parked session's
  # identity problem. So the fingerprint decides WHETHER there is anything new to
  # try, and MAX_EARLY_WAKES per EARLY_WAKE_WINDOW decides how often one session
  # may act on it. Past the cap the session falls back to its timer, which is the
  # behaviour it had before this fast path existed.
  #
  # An outage that heals on the vendor's side without touching any account row is
  # not visible to this sweep and still waits out its timer. That backstop is why
  # the trigger exists.
  #
  # @return [Integer] number of sessions resumed
  def self.wake_parked_sessions!(logger: nil)
    logger ||= StructuredLogger.new({ service: "AuthOutageParkService" })
    resumed = 0

    # One read of each runtime's pool for the whole sweep. Re-reading per session
    # is both wasted work and a way for two sessions in the same sweep to be
    # judged against different pools.
    available = {}
    fingerprints = {}
    # Per runtime, not global: the hazard the cap guards is one POOL being
    # re-drained by everything parked on it, so a fleet of claude_code parks
    # must not hold back the codex sessions whose own pool just recovered.
    woken_per_runtime = Hash.new(0)
    held = 0

    # `.each`, not `find_each`: find_each imposes its own primary-key order and
    # would discard the oldest-park-first ordering the cap below depends on. The
    # set is bounded by how many sessions can be asleep at once.
    parked_sessions.each do |session|
      runtime = session.agent_runtime
      next unless available.fetch(runtime) { available[runtime] = runtime_has_available_account?(runtime) }

      if session.metadata&.dig("auth_outage_reason") == AUTH_UNRECOVERABLE
        current = fingerprints.fetch(runtime) { fingerprints[runtime] = pool_fingerprint(runtime) }
        next unless auth_park_wakeable?(session, current, logger)
      end

      # Past the cap, and eligible: this session keeps its timer and its place at
      # the front of the next sweep. Counted rather than dropped silently — a
      # sweep that resumed 5 of 40 eligible sessions must not read as "5 were
      # eligible". The check sits AFTER the eligibility gates so an auth park held
      # here spends none of its early-wake budget.
      if woken_per_runtime[runtime] >= MAX_WAKES_PER_SWEEP
        held += 1
        next
      end

      next unless resume_parked!(session, logger)

      resumed += 1
      woken_per_runtime[runtime] += 1
    end

    if held.positive?
      logger.info("Held parked sessions past the per-sweep wake cap",
        resumed: resumed, held: held, cap: MAX_WAKES_PER_SWEEP)
    end

    resumed
  end

  # Has the pool changed for an AUTH_UNRECOVERABLE park since it was parked, and
  # does it still have early-wake budget left?
  #
  # @param current [String, nil] the runtime's pool fingerprint right now
  def self.auth_park_wakeable?(session, current, logger)
    parked_fingerprint = session.metadata&.dig(POOL_FINGERPRINT_KEY)
    # Parked before the fingerprint was recorded (an older park, or one whose
    # fingerprint could not be computed). There is nothing to compare against,
    # and "wake anyway" is the resume loop, so the timer remains its way back.
    return false if parked_fingerprint.blank?
    return false if current.blank? || current == parked_fingerprint

    spent = recent_early_wakes(session).size
    if spent >= MAX_EARLY_WAKES
      logger.info("Auth-outage park has spent its early wakes — leaving it to the timer",
        session_id: session.id, early_wakes: spent, window: EARLY_WAKE_WINDOW.inspect)
      return false
    end

    true
  end

  # The session's sweep-driven wakes still inside the rolling window, oldest
  # first. Doubles as the pruner: what it returns is what gets written back, so
  # the log cannot grow past MAX_EARLY_WAKES entries.
  def self.recent_early_wakes(session)
    cutoff = EARLY_WAKE_WINDOW.ago

    Array(session.metadata&.dig(EARLY_WAKE_LOG_KEY)).filter_map do |stamp|
      at = Time.zone.parse(stamp.to_s) rescue nil
      at if at && at > cutoff
    end
  end

  # This session's quota parks still inside the rolling window, oldest first.
  # Doubles as the pruner: what it returns is what gets written back, so a park
  # that has aged out of QUOTA_PARK_WINDOW stops counting against the floor.
  def self.recent_quota_parks(session)
    cutoff = QUOTA_PARK_WINDOW.ago

    Array(session.metadata&.dig(QUOTA_PARK_LOG_KEY)).filter_map do |stamp|
      at = Time.zone.parse(stamp.to_s) rescue nil
      at if at && at > cutoff
    end
  end

  # A digest of the credentials that can serve this runtime right now: every
  # available account's id paired with a digest of its stored oauth_config.
  #
  # Content-addressed rather than an `updated_at` comparison. updated_at churns
  # for things that are not credential changes at all — a rotation stamping
  # last_rotated_to_at, a quota_hit_count bump, a filesystem sync that adopts an
  # identical config — and every one of those would read as "the pool changed".
  #
  # Salted with the app's secret so the stored digest cannot be used offline to
  # confirm a guessed token: the fingerprint lives in session metadata, which
  # agents can read back through the MCP get_session tool.
  #
  # @return [String, nil] nil if the pool could not be read at all
  def self.pool_fingerprint(runtime)
    parts = RuntimeAuthProvider.for(runtime).accounts.available.map do |account|
      "#{account.id}:#{Digest::SHA256.hexdigest(account.oauth_config.to_json)}"
    end

    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base.to_s, parts.sort.join("|"))
  rescue => e
    Rails.logger.info "[AuthOutageParkService] Could not fingerprint the #{runtime} pool: #{e.message}"
    nil
  end

  # Sessions currently dormant because of an auth outage, oldest park first.
  #
  # The order is what makes MAX_WAKES_PER_SWEEP fair rather than arbitrary: the
  # session asleep longest goes in the first batch, instead of the sweep
  # re-picking whichever ids sort lowest every 15 minutes and starving the rest.
  # A session that re-parks earns a newer stamp and goes to the back. Sorting is
  # lexicographic over the stored string, which is why #record_outage! writes that
  # stamp in UTC.
  def self.parked_sessions
    Session
      .where(status: :waiting)
      .where("metadata->>'auth_outage_reason' IS NOT NULL")
      .order(Arel.sql("metadata->>'auth_outage_parked_at' ASC NULLS FIRST"))
  end

  # This session's auth-outage retry triggers. Matched on the name Zimmer wrote,
  # so a `wake_me_up_later` wake the USER set up for the same session — identical
  # reuse_session + last_session_id shape — is never swept up with them. The
  # prefix carries no LIKE metacharacters and the id it embeds is an integer, so
  # "… #1 at %" cannot reach "#12 at …"; keep it that way.
  #
  # `failed` is excluded for the reason CleanupStaleTriggersJob excludes it: a
  # trigger ScheduleTriggerJob parked there is a deliberate tombstone, left in
  # place so the operator can see a wake did not fire and re-arm it. Only they
  # clear it.
  def self.retry_triggers_for(session)
    Trigger
      .where(last_session_id: session.id, reuse_session: true)
      .where.not(status: "failed")
      .where("name LIKE ?", "#{RETRY_TRIGGER_NAME_PREFIX} ##{session.id} at %")
  end

  # Destroy this session's retry triggers — at the two moments one stops being
  # able to do anything: a new park supersedes it, and a sweep resume spends it.
  #
  # Without this they accumulate. A resume consumes the wake-up CONDITION
  # (SessionStateMachine#cancel_pending_one_time_wake_triggers stamps
  # last_triggered_at) but leaves the trigger row enabled, having created no
  # session. ScheduleTriggerJob's auto-delete only runs on a trigger that actually
  # FIRES, so it never sees these, and CleanupStaleTriggersJob reaps them an hour
  # after a scheduled_at that can be twelve hours out. Across a park/resume/re-park
  # loop that is a column of identical dead rows in the trigger list, each
  # surviving ~13 hours.
  #
  # Best-effort: a park whose cleanup fails is still a park, and a resume whose
  # cleanup fails is still a resume.
  #
  # @param except [Trigger, nil] a trigger to keep — the successor, when this is
  #   called to clear the ones it replaces
  # @return [Integer] number of triggers destroyed
  def self.discard_retry_triggers!(session, reason:, logger: nil, except: nil)
    destroyed = 0

    scope = retry_triggers_for(session)
    scope = scope.where.not(id: except.id) if except&.id

    scope.find_each do |trigger|
      trigger.destroy!
      destroyed += 1
    end

    if destroyed.positive?
      (logger || Rails.logger).info(
        "[AuthOutageParkService] Destroyed #{destroyed} auth-outage retry trigger(s) " \
        "for session #{session.id} — #{reason}"
      )
    end

    destroyed
  rescue => e
    # Names the class: the visible symptom of this failing is the trigger list
    # stacking up again, which is the thing this method exists to prevent.
    Rails.logger.warn "[AuthOutageParkService] Could not discard retry triggers for " \
      "session #{session.id} (#{e.class}): #{e.message}"
    destroyed
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
  #
  # An auth park spends one of its early wakes in the same write, under the same
  # lock. Charging it afterwards instead would race the job this method enqueues
  # for the whole-column metadata write, and would leave the budget uncharged
  # (so the cap bounding nothing) if that second write failed.
  def self.resume_parked!(session, logger)
    reason = nil
    prompt = nil

    ActiveRecord::Base.transaction do
      session.lock!
      raise ActiveRecord::Rollback unless session.waiting? && session.may_resume?

      reason = session.metadata&.dig("auth_outage_reason")
      raise ActiveRecord::Rollback if reason.blank?

      prompt = AutomatedPrompts.system_recovery(reason: resume_prompt_reason(reason))

      metadata = (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)
      if reason == AUTH_UNRECOVERABLE
        metadata[EARLY_WAKE_LOG_KEY] =
          (recent_early_wakes(session) + [ Time.current ]).map { |at| at.utc.iso8601 }
      end

      session.update!(running_job_id: nil, metadata: metadata)
      session.resume!

      # Stamp the prompt BEFORE leaving the transaction, and after `resume!` so a reader
      # that sees the marker is guaranteed to also see `running` (the same ordering, and
      # the same reason, as Session#deliver_follow_up!).
      #
      # Without it this method resumes a session to `running` while its job does not yet
      # exist and `running_job_id` is nil — and CleanupOrphanedSessionsJob calls a running
      # session with a blank running_job_id "DEFINITELY orphaned" with no grace period. A
      # sweep landing in that window reaps the resume, hijacks the session with a
      # resume-monitoring job pointed at a stale pid, and the recovery turn never runs.
      # `pending_follow_up_prompt` is the marker that sweep already honours.
      session.merge_metadata!(
        "pending_follow_up_prompt" => prompt,
        "pending_follow_up_sent_at" => Time.current.utc.iso8601
      )
    end

    return false if reason.blank? || !session.reload.running?

    # The resume above consumed the retry trigger's condition; drop the row with
    # it, so a session that parks and recovers repeatedly leaves one trigger
    # behind at a time rather than one per park.
    discard_retry_triggers!(session, reason: "resumed by the recovery sweep", logger: logger)

    session.logs.create!(level: "warning", content: resume_message(reason))

    # Record running_job_id as soon as the job exists, closing the rest of the same
    # window: past this point the sweep has a live job to look at rather than a blank.
    job = AgentSessionJob.enqueue_with_prompt(session.id, prompt)
    job_id = job.try(:job_id)
    if job_id.present?
      session.update!(running_job_id: job_id)
    else
      logger.warn("Resumed parked session but no job id was returned", session_id: session.id)
    end
    logger.info("Resumed session parked for auth outage", session_id: session.id, reason: reason)
    true
  rescue => e
    logger.warn("Failed to resume parked session", session_id: session.id, error: e.message)
    false
  end

  # What the user reads in the session log when the sweep resumes them. The two
  # reasons resumed on different evidence, so they say different things: a quota
  # park waited for the pool to refill, an auth park waited for the credentials
  # in it to change.
  def self.resume_message(reason)
    if reason == AUTH_UNRECOVERABLE
      "The login pool changed since this session was parked (auth unrecoverable) — " \
        "resuming automatically to try the new credentials."
    else
      "Login pool recovered (#{reason.tr('_', ' ')}) — resuming this session automatically."
    end
  end

  # The same distinction as {.resume_message}, phrased for the agent rather than for the
  # session log. The two park reasons resumed on different evidence and must not be
  # collapsed: a quota park waited for the pool to refill, an auth park waited for the
  # credentials in it to change, and telling an agent its pool was exhausted when the
  # real story was a bad credential sends it looking for the wrong thing.
  def self.resume_prompt_reason(reason)
    if reason == AUTH_UNRECOVERABLE
      "this session was parked because its login credentials were not usable, " \
        "and the login pool has since changed"
    else
      "this session was parked because the login pool was exhausted (#{reason.tr('_', ' ')}), " \
        "and the pool has recovered"
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

    floor = (reason == QUOTA_EXHAUSTED) ? quota_retry_floor : MIN_RETRY_DELAY

    # Jitter lands after the clamp on purpose. Applied before it, the floor would
    # swallow it whole in exactly the case that most needs the spread: a whole
    # population parked together and pinned to the same minimum.
    #
    # The CEILING swallows it the same way, and that is the case the observed
    # trigger waves came from — a weekly reset or a sentinel expiry sits far
    # enough out that every session in the outage pins to MAX_RETRY_DELAY, and
    # jitter added on top of the ceiling just clamps back down onto it. So the
    # pre-jitter clamp stops one jitter window short of the ceiling, leaving the
    # spread somewhere to go. `.max` with the floor keeps the low bound at or
    # below the high one: `clamp` raises otherwise, and park!'s rescue would turn
    # that into a session parked with no retry at all.
    ceiling = [ MAX_RETRY_DELAY - RETRY_JITTER, floor ].max
    target = target.clamp(floor.from_now, ceiling.from_now)

    (target + rand(RETRY_JITTER.to_i)).clamp(floor.from_now, MAX_RETRY_DELAY.from_now)
  end

  # The floor under a quota park's retry, widened by one doubling for each
  # consecutive park this session has already spent inside QUOTA_PARK_WINDOW.
  #
  # Held at or below the ceiling: `clamp` raises when its low bound is above its
  # high one, and the caller's rescue would turn that into a session parked with
  # no retry at all. The two constants leave room today, so this is a guard
  # against a later change to either, not a live condition.
  def quota_retry_floor
    steps = [ self.class.recent_quota_parks(session).size, MAX_QUOTA_PARK_BACKOFF_STEPS ].min

    [ MIN_RETRY_DELAY * (2**steps), MAX_RETRY_DELAY ].min
  end

  def earliest_pool_reset
    accounts = ClaudeAccount.quota_exceeded.for_runtime(session.agent_runtime).to_a
    return nil if accounts.empty?

    per_account = accounts.filter_map do |account|
      snapshot = account.latest_snapshot
      next unless snapshot

      future = [ snapshot.reset_5h, snapshot.reset_7d ].compact.select { |t| t > Time.current }.max
      next future if future

      # No future reset stamp. That reads as "clears now" only if the healer
      # agrees, because the healer is what would make it true: QuotaResetCheckerJob
      # restores an account when its snapshot is #windows_clear?.
      #
      # For a stamp that has genuinely passed the two agree — the sliding window
      # turned over, ClaudeAccountQuotaSnapshot.effective_utilization discounts
      # the counter to zero, and the next tick restores the account. They part
      # company on a snapshot carrying NO stamps at all, which is a real reading:
      # with no reset time to have passed, the weekly counter still stands, so
      # #seven_day_window_spent? holds and the account stays exceeded. Calling
      # that "now" pins every parked session to the retry floor and wakes them
      # all back into the same exhausted pool five minutes later. Its reset time
      # is simply unknown, and DEFAULT_RETRY_DELAY is what unknown means here.
      Time.current if snapshot.windows_clear?
    end

    per_account.min
  rescue => e
    @logger.info("Could not derive quota reset time from snapshots", error: e.message)
    nil
  end

  def record_outage!(reason, retry_at)
    outage = {
      "auth_outage_reason" => reason,
      # UTC explicitly: .parked_sessions orders on this value as a STRING, and an
      # embedded offset would make that lexicographic sort disagree with
      # chronological order, quietly costing the sweep's cap its fairness. With
      # config.time_zone left at its default this already emitted `…Z`, so this
      # is a guard against setting that, not a fix for a live defect.
      "auth_outage_parked_at" => Time.current.utc.iso8601,
      "auth_outage_retry_at" => retry_at.utc.iso8601
    }

    with_db_retry do
      # The pool that just failed this session. wake_parked_sessions! wakes an
      # AUTH_UNRECOVERABLE park only once this stops describing the pool. Read
      # inside the retry because it is a DB read like the write below: a blip
      # that dropped it would cost this park its fast path for the rest of its
      # life, since an absent fingerprint means "nothing to compare against".
      fingerprint = self.class.pool_fingerprint(session.agent_runtime)
      outage[POOL_FINGERPRINT_KEY] = fingerprint if fingerprint.present?

      # Reload first: schedule_wake! ran Trigger's auto-sleep callback, which
      # wrote pending_sleep straight to the row. Merging into the in-memory copy
      # would clobber it — and pending_sleep is the whole mechanism by which a
      # parked session actually goes dormant.
      session.reload
      metadata = (session.metadata || {}).merge(outage)

      # Charge this park to the backoff log, reading the reloaded row so the
      # count is the parks spent BEFORE this one — which is what
      # #quota_retry_floor already priced the retry on. Trimmed to the number of
      # doublings the floor can actually use, so the list cannot grow with a
      # session that parks its way through a long outage.
      if reason == QUOTA_EXHAUSTED
        metadata[QUOTA_PARK_LOG_KEY] =
          (self.class.recent_quota_parks(session) + [ Time.current ])
            .last(MAX_QUOTA_PARK_BACKOFF_STEPS)
            .map { |at| at.utc.iso8601 }
      end

      session.update!(metadata: metadata)
    end
  end

  # Reuses the same one-time-schedule trigger shape as the wake_me_up_later MCP
  # tool: `reuse_session` + `last_session_id` means firing resumes THIS session
  # rather than spawning a new one, and Trigger#sleep_target_session_if_applicable
  # is what actually puts the session to sleep.
  #
  # A session gets at most one of these at a time. The successor is created
  # first and the predecessors destroyed after, for the same reason park! writes
  # the metadata only once this method has returned: if the create fails, the
  # session keeps whatever backstop it already had rather than being left with a
  # promise and nothing to keep it. See .discard_retry_triggers!.
  def schedule_wake!(reason, retry_at)
    scheduled_at = retry_at.utc.strftime("%Y-%m-%dT%H:%M:%S")

    trigger = Trigger.create!(
      name: "#{RETRY_TRIGGER_NAME_PREFIX} ##{session.id} at #{scheduled_at}Z",
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

    self.class.discard_retry_triggers!(session, reason: "superseded by a new park",
      logger: @logger, except: trigger)

    trigger
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
