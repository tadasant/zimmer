# frozen_string_literal: true

require "automated_prompts"

# Parks a session that cannot make progress because the runtime's login pool has
# nothing usable left, and leaves it dormant until the pool comes back.
#
# == When this fires ==
#
# Two exit decisions in ProcessLifecycleManager mean "we are out of runway":
#
#   1. :quota_exceeded with no rotation target — every account in the pool is
#      quota_exceeded, so AccountRotationService#rotate! returns
#      { success: false, reason: "no_available_accounts" }.
#   2. Auth recovery that cannot succeed — the CLI reports
#      "Not logged in \u00b7 Please run /login" and re-injecting credentials does not
#      fix it (either no account is available at all, or the injected identity is
#      rejected again on every attempt).
#
# Neither is a state a bare `needs_input` communicates. The only visible artifact
# would be the CLI's own "Not logged in \u00b7 Please run /login" text, which says
# nothing about the cause, notifies nobody, and leaves the session stopped even
# after the condition clears.
#
# == What parking does ==
#
# 1. Writes an unmistakable session log naming the outage.
# 2. Sends a push notification so the user learns about it away from the UI.
# 3. Records the outage on the session (`auth_outage_*` metadata).
# 4. Puts the session to sleep. A `waiting` session is dormant: the heartbeat
#    sweep anchors its cadence instead of nudging it, so a parked session cannot
#    be re-poked into the same wall. A session that is still RUNNING is marked
#    `pending_sleep` and carried needs_input \u2192 waiting by the pause callback;
#    one that has already come to rest is slept outright.
#
# == Waking is an event, not a timer ==
#
# A park used to create a one-off schedule trigger per session, guessing at when
# the pool would recover. Those rows scaled with the number of PARKED SESSIONS
# rather than with the number of outages \u2014 dozens of "Auth outage retry for
# session #N" triggers at a time \u2014 and a wall clock knows nothing about which
# parked session matters most.
#
# Nothing is scheduled here now. Two things wake a parked session, and they cover
# different populations:
#
#   * SPOT sessions wait for the `quota_available` trigger event
#     (QuotaAvailabilityMonitor), which fires once on the pool's recovery and
#     spawns one fleet-maintenance session. That session decides who starts, in
#     precedence order, against the spot thresholds and the concurrency ceiling.
#     Zimmer does not duplicate that policy here.
#   * PRIORITY sessions are resumed directly by .wake_parked_sessions!, which
#     QuotaResetCheckerJob runs every fifteen minutes. Priority work is never
#     gated on quota, so making it wait on a spawned session's first turn would
#     be a regression.
#
# `auth_outage_pool_recovers_at` is recorded when the pool's own snapshots say
# when they roll over. It is an ESTIMATE for the banner to show, not a promise:
# nothing reads it back, and nothing fires at it.
#
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
    auth_outage_pool_recovers_at
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
  # keeps the bound meaningful: without one, a pool whose credentials churn (a
  # token sync, an account added and removed) would re-wake the same broken
  # identity indefinitely.
  EARLY_WAKE_LOG_KEY = "auth_outage_early_wakes"
  MAX_EARLY_WAKES = 3
  EARLY_WAKE_WINDOW = 6.hours

  # How many parked PRIORITY sessions one sweep may resume.
  #
  # .wake_parked_sessions! resumes on "the pool has an available account again",
  # which becomes true for every session parked on that pool in the same instant.
  # Resuming all of them in one pass put the whole population back on a pool with
  # one account in it, which they re-drained in seconds and re-parked together.
  #
  # A batch instead. The throttle closes its own loop: the next sweep is 15
  # minutes away and re-reads the pool, so if the batch that went first drained
  # it again, nobody else is woken. Held sessions lose nothing — each keeps its
  # place at the front of the next sweep's queue.
  MAX_WAKES_PER_SWEEP = 5

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

  # Park the session: put it to sleep, and record why.
  #
  # @param reason [String] one of REASONS
  # @param detail [String, nil] extra context appended to the log line (e.g. the
  #   quota message from the transcript)
  # @return [Boolean] true when the session was parked
  def park!(reason:, detail: nil)
    raise ArgumentError, "unknown park reason: #{reason}" unless REASONS.include?(reason)
    return false unless session

    # An estimate for the banner, not a schedule. Nothing fires at it.
    recovers_at = (reason == QUOTA_EXHAUSTED) ? earliest_pool_reset : nil

    # Sleep BEFORE recording, for the same reason the old path created its trigger
    # first: the metadata is what renders the banner saying the session is dormant
    # and will come back, so writing it while the session sat awake in needs_input
    # would put a promise on screen that nothing was keeping.
    sleep_session!

    add_log(park_message(reason, recovers_at, detail), level: "error")
    log_buffer&.flush

    record_outage!(reason, recovers_at)

    # A park is POSITIVE evidence that the pool is empty, and the earliest Zimmer
    # has it. QuotaAvailabilityMonitor otherwise only samples every fifteen
    # minutes, so an outage that opens and closes inside one tick is never
    # observed as unavailable — the recovery is then not an edge, no event fires,
    # and everything parked in that window waits forever. Recording it here is
    # what makes the next recovery a real rising edge.
    QuotaAvailabilityMonitor.record_unavailable!(runtime: session.agent_runtime) if reason == QUOTA_EXHAUSTED

    notify!(reason)

    @logger.warn("Session parked for auth outage",
      reason: reason, pool_recovers_at: recovers_at&.utc&.iso8601)

    true
  rescue ArgumentError
    # A bad reason is a programmer error, not an outage — don't swallow it.
    raise
  rescue => e
    # Parking is a best-effort improvement on top of the exit decision the
    # caller has already made. If it fails, the session still lands in
    # needs_input — it just doesn't go dormant.
    @logger.error("Failed to park session for auth outage", reason: reason, error: e.message)
    false
  end

  # A session that stops with its turn still undelivered, while its runtime's login pool
  # has nothing left to serve it, has not finished anything — it has hit the outage. Park
  # it into `waiting` instead of letting the caller pause it onto the human's action queue.
  #
  # This is the guard the resume-failure and turn-completion exit paths were missing. They
  # answer "the process is gone" with `pause!`, which is right for a turn that ran and
  # ended and wrong for one that never started: the session lands in needs_input claiming
  # to want a human, while the prompt Zimmer meant to deliver sits unconsumed in metadata
  # and the pool it was blocked on is still empty.
  #
  # Every condition below is required, and each one exists because parking a session that
  # should not be parked is its own bug — it sleeps, wakes on a reset, and nudges an agent
  # with nothing to do:
  #
  #   * The session is still `running`. A user pause terminates the process BEFORE
  #     transitioning (SessionsController), so the monitoring loop can reach these exits
  #     with a dead process and a session the human has already stopped. Putting it back
  #     to sleep would undo their decision.
  #   * It is not already parked. `auth_outage_reason` is cleared by every resume, so its
  #     presence means "parked right now" — and two of the three call sites can be reached
  #     in the same pass through the monitoring loop, which would otherwise send two push
  #     notifications for one stop.
  #   * The turn is provably undelivered — see #turn_undelivered?. Not merely "the marker
  #     was never cleared": only ONE exit path clears it, and it is not one of these.
  #   * The pool is CONFIRMED empty — see #pool_confirmed_empty?. A pool we could not read
  #     is not evidence of an outage.
  #
  # The caller still performs its own `pause!`. #park! marks the running session
  # `pending_sleep`, and the pause callback is what carries it needs_input → waiting.
  # So: park first, pause second. The session is reloaded before returning either way, so
  # a caller that merges into `session.metadata` afterwards cannot clobber the
  # `pending_sleep` written straight to the row.
  #
  # @param session [Session, nil]
  # @return [Boolean] true when the session was parked, and the caller must not also mark
  #   this stop as a recovery-continuable pause
  def self.park_undelivered_turn!(session, log_buffer: nil, logger: nil)
    return false unless session

    session.reload
    return false unless session.running?
    return false if session.metadata&.dig("auth_outage_reason").present?
    return false if session.metadata&.dig("paused_by") == "user"
    return false unless turn_undelivered?(session)
    return false unless pool_confirmed_empty?(session.agent_runtime)

    new(session, log_buffer: log_buffer, logger: logger)
      .park!(reason: QUOTA_EXHAUSTED, detail: UNDELIVERED_TURN_DETAIL)
  rescue => e
    # Same posture as #park!: this is an improvement on top of the exit decision the
    # caller already made, never a reason that decision cannot be carried out.
    Rails.logger.warn "[AuthOutageParkService] Could not park undelivered turn for session " \
      "#{session&.id} (#{e.class}): #{e.message}"
    false
  ensure
    session&.reload
  end

  # Did the turn Zimmer was delivering never reach the runtime?
  #
  # The tempting answer is "`active_follow_up_prompt` is still set", and it is wrong.
  # AgentSessionJob removes that key in exactly one place — the `:needs_input` branch of
  # the exit decision — and the paths this guard protects are the *fallbacks*, which never
  # clear it. So a turn that ran to completion and exited through one of them still carries
  # the marker, and on the `end_turn`-plus-dead-process fallback that is the strongest
  # evidence available that the turn DID complete.
  #
  # So require positive evidence instead: the prompt Zimmer sent is absent from the
  # conversation the runtime persisted. That is the same comparison TranscriptPollerService
  # makes to decide whether a follow-up has landed, and it is what actually distinguishes
  # session 6597 — whose transcript never grew past the 115 messages it held before the
  # park — from a session that answered its follow-up and stopped.
  #
  # An unreadable transcript answers `false`: unproven is not undelivered, and the caller's
  # existing pause is the safe default.
  def self.turn_undelivered?(session)
    prompt = session.metadata&.dig("active_follow_up_prompt").to_s.strip
    return false if prompt.blank?

    session.parsed_transcript.none? { |event| user_message_text(event).include?(prompt) }
  rescue => e
    Rails.logger.info "[AuthOutageParkService] Could not read transcript for session " \
      "#{session&.id} (#{e.class}): #{e.message}"
    false
  end

  # The text of a transcript entry, when it is a user message. Content arrives as a bare
  # string or as an array of content blocks depending on the runtime and the turn.
  def self.user_message_text(event)
    return "" unless event.is_a?(Hash) && event["type"] == "user"

    content = event.dig("message", "content")
    case content
    when String then content
    when Array then content.filter_map { |block| block.is_a?(Hash) ? block["text"] : block }.join("\n")
    else ""
    end.to_s
  end

  # Is the runtime's pool CONFIRMED to have nothing available?
  #
  # .runtime_has_available_account? cannot answer this, and the difference matters because
  # the two callers need its failure to fall opposite ways. There, a rescue to `false`
  # means "do not wake", which is conservative. Here the same `false` would mean "park",
  # which is not: a transient database blip, or a runtime with no accounts configured at
  # all, would park a session that is not blocked on quota — and a pool that is
  # permanently empty never satisfies the wake sweep, so the session would park, time out,
  # finish, and park again for as long as it lived.
  #
  # So read the pool directly and treat an unreadable one as "not confirmed".
  #
  # Through ClaudeAccount.any_serviceable_for?, the same predicate
  # AuthRecoveryCoordinator#park_reason_for_pool and #auth_health ask: an account
  # whose `status` column says quota_exceeded while its own latest reading says
  # both windows are clear can serve this turn, and parking a session against it
  # is the false positive this guard exists to avoid.
  def self.pool_confirmed_empty?(runtime)
    !ClaudeAccount.any_serviceable_for?(runtime)
  rescue => e
    Rails.logger.info "[AuthOutageParkService] Could not confirm the pool is empty for " \
      "runtime #{runtime}: #{e.message}"
    false
  end

  # Resume every parked PRIORITY session whose runtime can plausibly serve it
  # again. Called by QuotaResetCheckerJob right after it restores quota_exceeded
  # accounts to active, so the accounts and the priority work blocked on them
  # recover together.
  #
  # == Spot sessions are not this sweep's business ==
  #
  # A parked SPOT session stays parked here. Spot work is exactly the work whose
  # order matters when quota is scarce, and this sweep has no notion of order: it
  # takes the oldest parks first and stops at a cap. Waking them in that order
  # would be the arbitrary start the precedence column exists to replace.
  #
  # They wake on the `quota_available` trigger event instead — one fleet-maintenance
  # session per recovery, which reads precedence, the spot thresholds and the
  # concurrency ceiling and decides who runs. See QuotaAvailabilityMonitor.
  #
  # Priority work is never gated on quota, so it keeps the direct resume: making it
  # wait for a spawned session to take its first turn would be a regression, and
  # there is no ordering question to get wrong.
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
  # that can turn a rejected identity into a working one. No change, no wake.
  #
  # It is a coarse signal, not a repair detector. The same digest also moves when
  # RefreshRuntimeAuthTokensJob's 5-minute sync adopts a token the CLI rotated on
  # disk for the current account, which says nothing about a parked session's
  # identity problem. So the fingerprint decides WHETHER there is anything new to
  # try, and MAX_EARLY_WAKES per EARLY_WAKE_WINDOW decides how often one session
  # may act on it.
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
    paused_until = 0

    # One batched read of "who is asleep on a wake-up they chose" for the whole
    # sweep, in the same shape as the pool reads above and for the same reason.
    sleeping = Session.ids_paused_until_scheduled_time(parked_sessions.pluck(:id))

    # `.each`, not `find_each`: find_each imposes its own primary-key order and
    # would discard the oldest-park-first ordering the cap below depends on. The
    # set is bounded by how many sessions can be asleep at once.
    # Spot AUTH parks this sweep found eligible but will not resume itself.
    #
    # Only auth parks. A quota-parked spot session is woken by the pool's own
    # rising edge, which QuotaAvailabilityMonitor already fires — asking again
    # for it would be a second request for a wake that is on its way. An auth
    # park has no such edge: it is woken by the pool's CREDENTIALS changing,
    # which happens with `accounts.available` true the whole time. Without this
    # it would have no wake path at all.
    spot_eligible = 0

    parked_sessions.each do |session|
      # A pause outranks the un-park, and it outranks being priority. This session
      # is parked on the pool AND asleep on a wake-up somebody chose; the pool
      # recovering answers the first and says nothing about the second. Resuming
      # it here would also destroy the pause without a trace — #resume_parked!
      # goes through `resume!`, which consumes the session's pending one-time
      # wakes — so the guard has to sit ahead of every other reason to wake it.
      #
      # Ahead of the spot branch below too, so a paused spot park is not counted
      # as eligible and does not ask for a fleet wake it must not be started by.
      if sleeping.include?(session.id)
        paused_until += 1
        next
      end

      runtime = session.agent_runtime
      next unless available.fetch(runtime) { available[runtime] = runtime_has_available_account?(runtime) }

      if session.metadata&.dig("auth_outage_reason") == AUTH_UNRECOVERABLE
        current = fingerprints.fetch(runtime) { fingerprints[runtime] = pool_fingerprint(runtime) }
        next unless auth_park_wakeable?(session, current, logger)
      end

      # Eligible, but spot: this sweep has no notion of order, and ordering spot
      # work is the whole point of the fleet wake. Let that session decide,
      # rather than resuming it here out of order.
      unless session.priority?
        spot_eligible += 1 if session.metadata&.dig("auth_outage_reason") == AUTH_UNRECOVERABLE
        next
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

    if spot_eligible.positive?
      logger.info("Left parked spot auth-outage sessions to the ranked fleet wake", count: spot_eligible)
      QuotaAvailabilityMonitor.request_wake!(
        reason: "#{spot_eligible} parked spot session(s) whose pool credentials changed"
      )
    end

    if paused_until.positive?
      logger.info("Left parked sessions asleep on their own wake-ups", paused_until: paused_until)
    end

    resumed
  end

  # Has the pool changed for an AUTH_UNRECOVERABLE park since it was parked, and
  # does it still have early-wake budget left?
  #
  # @param current [String, nil] the runtime's pool fingerprint right now
  def self.auth_park_wakeable?(session, current, logger)
    parked_fingerprint = session.metadata&.dig(POOL_FINGERPRINT_KEY)
    # Parked before the fingerprint was recorded — an older park, or one whose
    # pool could not be read at the time. There is nothing to compare against, so
    # there is no evidence either way; wake it anyway rather than leave it
    # dormant forever. Nothing else would: the timer that used to be its way back
    # no longer exists. The early-wake budget below is what keeps "no evidence"
    # from becoming a resume loop.
    return within_early_wake_budget?(session, logger) if parked_fingerprint.blank?

    return false if current.blank? || current == parked_fingerprint

    within_early_wake_budget?(session, logger)
  end

  # Whether this park may spend another sweep-driven wake inside the window. Past
  # the budget it stays parked until a human resumes it or the pool changes
  # enough for a later sweep to grant one.
  def self.within_early_wake_budget?(session, logger)
    spent = recent_early_wakes(session).size
    return true if spent < MAX_EARLY_WAKES

    logger.info("Auth-outage park has spent its early wakes — leaving it parked",
      session_id: session.id, early_wakes: spent, window: EARLY_WAKE_WINDOW.inspect)
    false
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

  # Is this session dormant on an auth outage — the row-level form of the query
  # .parked_sessions runs over the fleet?
  #
  # The predicate exists because "dormant on purpose" is a question other code has
  # to ask about ONE session it is already holding, and the alternative is each
  # caller re-deriving `auth_outage_reason` and hoping it stays the marker.
  # `SpotSessionPause.paused?` is the sibling for the other park, and this reads
  # the same way at the call site.
  #
  # The `waiting` half is deliberate and matches .parked_sessions. A running
  # session can carry `auth_outage_reason` for the moments between #record_outage!
  # and the sleep that follows it, and it is not dormant then — it is a session
  # about to go to sleep, and answering "yes" for it would let a caller stand down
  # on a park that has not happened yet.
  #
  # @param session [Session, nil]
  # @return [Boolean]
  def self.parked?(session)
    return false unless session&.waiting?

    session.metadata&.dig("auth_outage_reason").present?
  end

  # The pool's earliest rollover as recorded at park time, parsed.
  #
  # An ESTIMATE for a surface to show — nothing reads it back and nothing fires
  # at it (see this class's header). It lives here rather than in a view helper
  # because `get_session` renders the same sentence for an agent that the session
  # page renders for a human, and the two must not drift.
  #
  # @param session [Session, nil]
  # @return [Time, nil]
  def self.pool_recovery_time(session)
    raw = session&.metadata&.dig("auth_outage_pool_recovers_at")
    return nil if raw.blank?

    Time.iso8601(raw.to_s)
  rescue ArgumentError
    nil
  end

  # Can the sweep hand this runtime's pool to a session it is about to start?
  #
  # The `status` column, deliberately, and not the evidence-based
  # .pool_confirmed_empty? asks. Waking is the opposite risk from parking: every
  # path that actually picks an account to spawn with — bootstrap, rotation,
  # injection — reads the column, so resuming a session against an account the
  # column still calls quota_exceeded starts it into a pool that will not serve
  # it. QuotaResetCheckerJob restores the column immediately before calling this
  # sweep, which is what keeps the two in step.
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
      # Re-asked under the lock, for a pause armed after the sweep read the set.
      # `resume!` below consumes the session's pending one-time wakes, so a miss
      # here does not merely start the session early — it erases the pause.
      raise ActiveRecord::Rollback if session.paused_until_scheduled_time?

      reason = session.metadata&.dig("auth_outage_reason")
      raise ActiveRecord::Rollback if reason.blank?

      prompt = AutomatedPrompts.system_recovery(reason: resume_prompt_reason(reason))

      updates = {}
      if reason == AUTH_UNRECOVERABLE
        updates[EARLY_WAKE_LOG_KEY] =
          (recent_early_wakes(session) + [ Time.current ]).map { |at| at.utc.iso8601 }
      end

      session.merge_metadata!(updates, Session::STALE_RETRY_METADATA_KEYS)
      session.update!(running_job_id: nil)
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

    session.logs.create!(level: "warning", content: resume_message(reason))

    # Record running_job_id as soon as the job exists, closing the rest of the same
    # window: past this point the sweep has a live job to look at rather than a blank.
    job = AgentSessionJob.enqueue_with_prompt(session.id, prompt)
    job_id = job.try(:job_id)
    if job_id.blank?
      logger.warn("Resumed parked session but no job id was returned", session_id: session.id)
    elsif session.reload.running? && session.running_job_id.blank?
      # Re-read under the same condition the write assumes. GoodJob can pick the job up,
      # deliver the turn and pause the session before this line runs, and stamping a job id
      # onto a session that is no longer running would hand orphan detection a job that has
      # already finished.
      session.update!(running_job_id: job_id)
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
  # An ESTIMATE for the banner, and nothing else — no timer fires at it. Each
  # quota_exceeded account's latest snapshot carries reset_5h / reset_7d, and
  # QuotaResetCheckerJob considers an account clear only when BOTH windows are
  # clear, so an account frees up at the LATER of its two future resets; the pool
  # frees up at the EARLIEST such account time. An auth outage has no published
  # clock, so it records nothing.
  def earliest_pool_reset
    accounts = ClaudeAccount.quota_exceeded.for_runtime(session.agent_runtime).to_a
    return nil if accounts.empty?

    # One query for the whole pool rather than one per account.
    snapshots = ClaudeAccountPool.latest_snapshots(accounts)

    per_account = accounts.filter_map do |account|
      snapshot = snapshots[account.id]
      next unless snapshot

      # This account is not waiting for anything: its own reading says both
      # windows are clear, so its reset stamps are merely when the counters next
      # roll over, not a recovery time. It contributes NOTHING — neither those
      # stamps, which would put the estimate at a weekly rollover nothing is
      # actually waiting for, nor a "now" that would win the minimum below and
      # promise a recovery the accounts that ARE blocked cannot deliver.
      next if snapshot.windows_clear?

      future = [ snapshot.reset_5h, snapshot.reset_7d ].compact.select { |t| t > Time.current }.max
      next future if future

      # A spent window carrying no future reset stamp — a real reading, and one
      # with no time in it to name. With no reset to have passed, the weekly
      # counter still stands, #seven_day_window_spent? holds and the account
      # stays exceeded; calling that "now" would pin every parked session to the
      # retry floor and wake them all back into the same exhausted pool five
      # minutes later. Its reset time is simply unknown, and an absent estimate
      # is what unknown means here.
      nil
    end

    per_account.min
  rescue => e
    @logger.info("Could not derive quota reset time from snapshots", error: e.message)
    nil
  end

  def record_outage!(reason, recovers_at)
    outage = {
      "auth_outage_reason" => reason,
      # UTC explicitly: .parked_sessions orders on this value as a STRING, and an
      # embedded offset would make that lexicographic sort disagree with
      # chronological order, quietly costing the sweep's cap its fairness. With
      # config.time_zone left at its default this already emitted `…Z`, so this
      # is a guard against setting that, not a fix for a live defect.
      "auth_outage_parked_at" => Time.current.utc.iso8601
    }
    outage["auth_outage_pool_recovers_at"] = recovers_at.utc.iso8601 if recovers_at

    with_db_retry do
      # The pool that just failed this session. wake_parked_sessions! wakes an
      # AUTH_UNRECOVERABLE park only once this stops describing the pool. Read
      # inside the retry because it is a DB read like the write below: a blip
      # that dropped it would cost this park its fast path for the rest of its
      # life, since an absent fingerprint means "nothing to compare against".
      fingerprint = self.class.pool_fingerprint(session.agent_runtime)
      outage[POOL_FINGERPRINT_KEY] = fingerprint if fingerprint.present?

      # The merge is a single statement, so #sleep_session!'s `pending_sleep` —
      # written straight to the row, and the whole mechanism by which a parked
      # session goes dormant — survives it whatever this object holds. The reload
      # is here so the in-memory copy the caller goes on to read is that row.
      session.reload
      session.merge_metadata!(outage)
    end
  end

  # Put the session to sleep, so it is dormant rather than sitting on the human's
  # action queue asking for attention it does not need.
  #
  # The same two cases Trigger#sleep_target_session_if_applicable handles, because
  # they are the same two states a session can be parked from. A RUNNING session
  # cannot be transitioned out from under its own turn, so it is marked
  # `pending_sleep` and the pause callback carries it needs_input → waiting once
  # the turn ends; a session already at rest is slept outright.
  #
  # Anything else — already waiting, archived, failed — is left alone: it is
  # dormant or terminal already, and forcing a transition would be the caller's
  # decision to undo, not this one's.
  def sleep_session!
    session.reload

    if session.needs_input?
      session.sleep!
    elsif session.running?
      session.merge_metadata!("pending_sleep" => true)
    else
      @logger.info("Not sleeping a parked session that is neither running nor idle",
        status: session.status)
    end
  end

  def notify!(reason)
    SendPushNotificationJob.perform_later(
      session.id,
      :custom_message,
      "#{headline(reason)} Session ##{session.id} is parked and resumes when the pool recovers."
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

  # What the parked sentence says depends on whether the session's own class means
  # it waits for the ranked fleet wake or recovers with the pool.
  def parked_sentence(recovers_at)
    who = if session.spot?
      "This session is parked (waiting). It resumes when the account pool recovers and the " \
        "fleet wake reaches it in precedence order."
    else
      "This session is parked (waiting) and resumes automatically once the account pool recovers."
    end

    return who if recovers_at.blank?

    "#{who} The pool's earliest reset is #{recovers_at.utc.iso8601}."
  end

  def park_message(reason, recovers_at, detail)
    action = case reason
    when QUOTA_EXHAUSTED
      "Every account in the pool is quota_exceeded, so there is nothing to rotate into."
    else
      "The runtime reported \"Not logged in\" and re-injecting credentials did not fix it."
    end

    [
      headline(reason),
      action,
      parked_sentence(recovers_at),
      detail.presence
    ].compact.join(" ")
  end

  def add_log(content, level: "info")
    if log_buffer
      log_buffer.add(content, level: level)
    else
      with_db_retry { session.logs.create!(content: content, level: level) }
    end
  end
end
