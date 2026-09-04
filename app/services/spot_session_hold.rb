# frozen_string_literal: true

# Holds a spot session at the starting line when a quota window has no room for
# it or every session slot is taken, and re-queues it to try again.
#
# A held session is left in `waiting` — Zimmer's existing "created, not started"
# status — and AgentSessionJob is re-enqueued with a delay. GoodJob persists a
# delayed job in Postgres, so the retry survives a worker restart or a deploy;
# nothing depends on this process staying alive.
#
# The delay carries a little jitter. Without it a backlog held in the same minute
# re-checks in the same minute forever, and every one of them reads the same
# fleet size before any of them has started — so the whole queue either stampedes
# past the cap together or waits together.
#
# It also BACKS OFF, and that is a queue-stability property rather than a
# politeness one. Jitter spreads a population out; it does not make it smaller.
# A flat re-check interval means a held population of N sessions puts a FIXED
# N / interval jobs per minute onto `agents` for as long as the hold lasts — an
# arrival rate that cannot fall when the system is struggling, which is exactly
# when it needs to. On 2026-08-20 that was ~80 quota-held sessions re-checking
# every ~11 minutes: a standing ~8 jobs/min against 16 `agents` threads, 11 of
# them occupied for hours by live sessions. When a host-latency episode pushed
# per-re-check service time into the tens of seconds, arrivals outran service and
# the GoodJob ready queue grew monotonically (152 -> 251 jobs, head of queue
# unmoved for 23 minutes) until `SystemHealthMonitorJob` paged. Every one of
# those re-checks was refused, because the pool was quota-exhausted the whole
# time. Doubling the interval on consecutive holds turns that fixed arrival rate
# into a decaying one: 10m, 20m, 40m, then whichever ceiling applies.
#
# The ceiling depends on WHY the session is held, because the two reasons clear
# on very different timescales. A utilization hold waits on a quota window coming
# back down, which takes hours; a fleet-cap hold waits on any running session
# finishing, which can happen at any moment. Backing both off to the same ceiling
# would either leave the utilization case re-checking pointlessly or make the
# fleet-cap case sluggish, so they get different ones.
#
# The cost is disclosed rather than hidden: a session can sleep longer than it
# strictly had to — up to its ceiling — if the condition clears early. That is
# bounded (an hour at worst), visible on the session page via HELD_RETRY_AT, and
# a human who wants it now can make the one session priority, which the hold
# message already says. Restarting the session resets the ladder (see
# METADATA_KEYS) but does not bypass the gate: a still-held session is held again,
# back at ten minutes.
#
# The hold is recorded in `metadata` so the session detail page can explain
# itself rather than looking mysteriously stuck, and a log line lands in the
# session's own log for the same reason.
#
# == Every turn is gated, not just the first one
#
# This used to gate only a session's FIRST start, on the reasoning that
# interrupting a conversation already underway strands work half-done. That
# reasoning was about a session mid-turn — and it let through the thing it was
# never meant to cover: an IDLE spot session being woken for a NEW turn.
#
# A wake is not a continuation. A fired `wake_me_up_later` backstop, a queued
# follow-up, a poller-delivered comment and a restart all arrive at
# AgentSessionJob carrying a prompt, and every one of them starts a fresh turn
# that spends fresh quota. On 2026-08-22, session 7504 — spot, precedence 75,
# 141 spot sessions queued behind it — woke on its own backstop trigger and ran
# a full turn at 17:30Z while this gate was reporting HELD at 87% of a 65%
# 5-hour target, force-pausing 22 running spot sessions. It was not far down
# the queue by accident; it never consulted the queue at all.
#
# So the gate is a choke point on turns. What still passes through spends
# nothing:
#
#   * `clone_only` — sets up a clone, spawns no agent.
#   * `resume_monitoring` — re-attaches to a process that is ALREADY running.
#     Holding it would orphan that process rather than save a token.
#
# One hold reason does not apply to a session that is ALREADY `running` when the
# gate runs: `fleet_at_cap`. Such a session has been flipped to `running` by
# whoever delivered the turn, so it is counted in
# `Session.running_claude_code_count` itself — refusing it for a full fleet would
# refuse it on the strength of its own slot, and would refuse every session
# SpotSessionPause resumes, which are flipped to `running` before their jobs run.
# The utilization reading has no such problem: the pool's windows are measured
# independently of this session.
#
# That exemption is keyed on the session's STATUS, never on "this turn carries a
# prompt". A resume the gate has already deferred is sitting in `waiting` and
# holds no slot, so its re-check is an admission like any other — keying on the
# prompt would have exempted the entire population this class creates, and the
# cap would go unenforced for exactly the sessions it was holding.
#
# == A deferral must not lose the turn, even when a second one arrives
#
# The refused prompt (with its images and files) rides the delayed job, and is
# written down on the session's own row so that losing that job does not lose
# the turn — see HELD_PROMPT and HELD_IMAGES. Two things keep that honest when a
# session is held for the best part of an hour and something delivers to it
# again in the meantime — an orchestrator's second child waking it, say:
#
#   * The gate takes CUSTODY of the turn, so `pending_follow_up_prompt` is
#     dropped. That marker means "a job has not picked this prompt up yet", and
#     AgentSessionJob prefers it over its own argument. Left in place, a second
#     delivery's marker would overwrite the first, and the first deferred job
#     would then deliver the second prompt and discard its own.
#   * A second refused turn is QUEUED rather than given a second delayed job. Two
#     jobs racing one session means the concurrency guard drops whichever loses,
#     so the later prompt goes into `enqueued_messages` — the durable queue
#     Zimmer already drains at a session's next turn boundary — and is delivered
#     after the deferred turn ahead of it.
class SpotSessionHold
  HELD_AT = "spot_hold_at"
  HELD_REASON = "spot_hold_reason"
  HELD_DETAIL = "spot_hold_detail"
  HELD_RETRY_AT = "spot_hold_retry_at"
  HELD_COUNT = "spot_hold_count"

  # Which shape of turn was refused, so the banner, the log line and
  # `get_session` can say "held before starting" or "held before its next turn"
  # rather than describing every hold as a session that never began.
  HELD_TURN = "spot_hold_turn"
  TURN_START = "start"
  TURN_RESUME = "resume"

  # The prompt a deferred RESUME turn is carrying, recorded on the SESSION as
  # well as on the delayed job.
  #
  # "The turn is DEFERRED, never dropped" is this class's central promise, and
  # the session's own row is what keeps it. A copy held only in the delayed job's
  # argument list is lost with that job when a worker is killed between the hold
  # record committing and the enqueue — see #sweep! for the production case — so
  # anything rebuilding the re-check replays the real prompt rather than
  # inventing a nudge.
  #
  # Written only for a resume, and cleared the moment the session gets through,
  # so it is not a standing copy of every prompt in the fleet. `metadata` already
  # carries prompts this way for the same reason (`pending_follow_up_prompt`).
  HELD_PROMPT = "spot_hold_prompt"

  # The images and files that same deferred RESUME turn is carrying, recorded
  # beside its prompt.
  #
  # Same argument as the prompt above, and the same failure without it. `hold!`
  # is handed the turn's attachments and puts them on the delayed job;
  # AgentSessionJob reads attachments out of its own arguments and nowhere else.
  # So a worker that died before the enqueue took the screenshot with it exactly
  # as surely as the prompt, and the re-arm brought back "here is the
  # screenshot, fix this" with the prompt and without the screenshot — under a
  # log line that named the prompt and said nothing about what was missing
  # (#890).
  #
  # DESCRIPTORS, not bytes. The attachments themselves are already durable on
  # the session's own volume; what the lost job took was the record of WHICH of
  # them belonged to this turn. That distinction is also why the volume cannot
  # simply be re-read here the way a re-armed START re-reads it (see #rearm!):
  # on a resume the volume holds every attachment the session has ever received,
  # including the ones earlier turns already consumed, so "everything on disk"
  # would put an old screenshot on a new turn. Replaying the WRONG attachments
  # is worse than replaying none — both are silent, and only one of them is also
  # wrong.
  #
  # Written and cleared with HELD_PROMPT, so the three are one record: a hold
  # that carries no attachment drops these rather than leaving an earlier hold's
  # behind.
  HELD_IMAGES = "spot_hold_images"
  HELD_FILES = "spot_hold_files"

  # The deferred turn itself, as opposed to the bookkeeping around it. Written
  # only for a resume, and any of the three not written by this hold is dropped
  # so a re-arm never replays half of one turn and half of another.
  HELD_TURN_KEYS = [ HELD_PROMPT, HELD_IMAGES, HELD_FILES ].freeze

  # Read by two callers, and the second is what keeps the backoff honest. `clear`
  # drops these when a session gets through — and the three "restart from scratch"
  # paths (the Restart button, `action_session`, `POST /api/v1/sessions/:id/restart`)
  # except them from the metadata they carry forward, so an explicit request to
  # start this session resets the ladder with it.
  #
  # That reset has to be a POSITIVE signal from the caller rather than something
  # inferred here. Those paths re-enter the gate looking exactly like a scheduled
  # re-check — no prompt, no resume flag — so without it a person clicking Restart
  # on a session sitting at 40 minutes would push it to an hour, which is the
  # opposite of what they asked for.
  METADATA_KEYS = ([ HELD_AT, HELD_REASON, HELD_DETAIL, HELD_RETRY_AT, HELD_COUNT,
                     HELD_TURN ] + HELD_TURN_KEYS).freeze

  # Spread over which held sessions re-check, so a backlog does not re-evaluate
  # in lockstep.
  RETRY_JITTER = 2.minutes

  # Consecutive holds double the re-check interval from SpotGateService::RETRY_DELAY
  # — 10m, 20m, 40m, and on until the ceiling for the hold's reason clamps it: on
  # the fourth rung for a utilization hold (80m clamped to 60m), the third for a
  # fleet-cap one (40m clamped to 30m).
  #
  # The ceilings, not this, are what bound the DELAY. This bounds the ARITHMETIC:
  # `steps` does keep climbing to here, and without the clamp a session held for
  # weeks would raise 2 to a four-figure power on every re-check only to hand the
  # bignum straight to `.min`.
  MAX_BACKOFF_STEPS = 5

  # Ceiling for a utilization hold. The pool's windows come back down over hours,
  # so re-checking more often than this cannot learn anything new — and this is
  # the reason that produces long-lived holds, and therefore the standing load.
  UTILIZATION_MAX_RETRY_DELAY = 1.hour

  # Ceiling for a fleet-cap hold. A slot frees whenever any running session ends,
  # which is unpredictable and often soon, so this stays short: the point of the
  # backoff is to stop a *stuck* population spinning, not to make a session that
  # could start in five minutes wait half an hour.
  FLEET_CAP_MAX_RETRY_DELAY = 30.minutes

  # The gate reasons this service backs off differently. Anything else — a reason
  # added later, or one of the fail-open reasons that never reaches a hold at all
  # — falls to the shorter ceiling, which is the safe direction to be wrong in.
  UTILIZATION_REASON = "at_utilization_limit"

  # The hold reasons that apply to a turn taken by a session that ALREADY HOLDS A
  # SLOT — one whose deliverer has flipped it to `running`. See the class
  # comment: it is counted in `Session.running_claude_code_count` itself, so only
  # the utilization reading can honestly refuse it.
  #
  # Not "a resume". A resume the gate has already deferred once sits in `waiting`
  # and holds nothing, so its re-check is an admission like any other and the
  # fleet cap applies to it in full. Keying this on the prompt rather than on the
  # session's status would exempt exactly the population this class creates.
  RUNNING_HOLD_REASONS = [ UTILIZATION_REASON ].freeze

  # How far past its own re-check time a hold has to be before #sweep! treats the
  # ladder as BROKEN rather than merely late.
  #
  # Sized against the two things that make an honest re-check late: the jitter
  # (up to RETRY_JITTER) and a backed-up `agents` queue. Ten minutes is well clear
  # of both, so a hold this far past due has no job coming.
  OVERDUE_GRACE = 10.minutes

  # How many stranded ladders one sweep re-arms. Each re-arm is an admission
  # attempt, and the gate refuses most of them cheaply — but a deployment that
  # has accumulated a large stranded population should walk it back onto the
  # ladder over a few passes rather than putting the whole backlog through the
  # gate in one minute.
  MAX_REARMS_PER_SWEEP = 10

  # Re-armed re-checks are spread over this window, for the same reason the
  # ordinary ladder carries jitter: a batch that all re-checks in the same second
  # reads the same fleet size before any of them has started.
  REARM_SPREAD = 3.minutes

  # The auth-outage park's own marker. AuthOutageParkService keeps its key list
  # as a bare `%w[]` with no per-key constant, so the one this service has to
  # exclude is named here rather than reaching into that array by index.
  AUTH_OUTAGE_REASON_KEY = "auth_outage_reason"

  # How many overdue holds one pass LOADS. The batch it re-arms is bounded by
  # MAX_REARMS_PER_SWEEP; this bounds the read, so a deployment that has stalled
  # en masse does not pull every stranded session's row — `transcript`, `prompt`,
  # `goal` and all — into one worker's memory (tadasant/zimmer#719).
  MAX_LOADED_PER_SWEEP = MAX_REARMS_PER_SWEEP * 5


  # === Reading a hold back ===

  # One hold record, with the two things every surface was missing: how OLD it
  # is, and whether the re-check it promises is still coming.
  #
  # A hold record is a SNAPSHOT. `detail` is the sentence the gate produced at
  # `held_at`, frozen on the row, so a surface that replays it in the present
  # tense answers "why is this waiting" with something that may have been false
  # for hours. On 2026-08-31 session 7507's page read "5 of 5 session slots
  # taken" at 13:39Z from a hold taken at 02:12Z, while the live gate said
  # `within_limits` and 1 of 5; the only tell was a "next check" time already in
  # the past, rendered as though it were upcoming.
  #
  # So a Record never hands out `detail` without also being able to say when it
  # was taken, and the two sentences below are the shared wording the session
  # page and `get_session` both render — the surfaces cannot drift.
  Record = Data.define(:detail, :reason, :turn, :count, :held_at, :retry_at) do
    include ActionView::Helpers::DateHelper

    def resuming? = turn == TURN_RESUME

    # Whether the re-check this hold promised is late enough to mean the ladder
    # has stopped. `retry_at` is the entire promise a held session rests on, so a
    # stamp in the past means nothing is scheduled to move this session.
    #
    # The grace defaults to OVERDUE_GRACE, and every surface takes that default,
    # because they must all draw the line in the same place. A re-check due one
    # second ago is not a stalled ladder — it is a job that has not been picked
    # up yet, and the window in which that is true is widest during exactly the
    # `agents` congestion this class's header documents. Naming that "stalled" on
    # the session page while /inference counted 0 overdue would be this PR's own
    # defect wearing the other face.
    def overdue?(now: Time.current, grace: OVERDUE_GRACE)
      retry_at.present? && retry_at + grace < now
    end

    def age(now: Time.current) = held_at.present? ? now - held_at : nil

    # "as of", said out loud. Nil when the hold carries no timestamp, so a
    # caller renders nothing rather than "as of unknown".
    def as_of_sentence(now: Time.current)
      return nil if held_at.blank?

      "That was the gate's reading #{distance_of_time_in_words(now, held_at)} ago " \
        "(#{held_at.utc.iso8601}), not a live one."
    end

    # What happens next, and whether it is still going to happen. An overdue
    # re-check is named as overdue rather than printed as an upcoming time.
    def recheck_sentence(now: Time.current)
      return "No re-check time was recorded for this hold." if retry_at.blank?

      if overdue?(now: now)
        "Its re-check was due #{distance_of_time_in_words(now, retry_at)} ago " \
          "(#{retry_at.utc.iso8601}) and has not fired, so the ladder has stalled. " \
          "Zimmer's spot-hold sweep re-arms it automatically."
      else
        "Next check #{retry_at.utc.iso8601}, in #{distance_of_time_in_words(now, retry_at)}."
      end
    end
  end

  # What one #sweep! pass did.
  #
  # The four numbers account for the whole overdue population, which is the point:
  # a pass that re-armed 5 of 40 must not read as "5 were stalled". `skipped` is
  # the ones whose re-check job is queued and merely running late; `deferred` is
  # the ones this pass did not reach — over the batch bound, or dormant for a
  # reason that outranks the hold.
  Sweep = Data.define(:rearmed, :overdue, :skipped, :deferred) do
    def to_h = { rearmed: rearmed, overdue: overdue, skipped: skipped, deferred: deferred }
  end

  class << self
    # True when the turn was refused and the caller should stop. False means
    # carry on and run it.
    #
    # @param session [Session]
    # @param follow_up_prompt [String, nil] the prompt this turn would deliver.
    #   Present means a resume — a wake, a follow-up, a poller message, a restart
    #   — and it is re-enqueued verbatim when the turn is deferred.
    # @param log_buffer [LogBuffer, nil]
    # @param images [Array<Hash>, nil] carried through to the retry unchanged
    # @param files [Array<Hash>, nil]
    def hold_if_needed(session, follow_up_prompt: nil, log_buffer: nil, images: nil, files: nil)
      return false unless session.spot?

      # The one seam. SpotGateService.allow_start? reads the same method, so the
      # readable predicate and the production path cannot drift apart.
      decision = SpotGateService.start_decision(session)
      if decision.allowed? || !applies_to?(decision, session)
        clear(session)
        return false
      end

      hold!(session, decision, follow_up_prompt: follow_up_prompt,
            log_buffer: log_buffer, images: images, files: files)
      true
    end

    # Drop the hold record once the session gets going, so a page showing a
    # running session never also shows a stale "held" banner.
    def clear(session)
      return if METADATA_KEYS.none? { |k| (session.metadata || {}).key?(k) }

      session.update_columns(metadata: (session.metadata || {}).except(*METADATA_KEYS))
    rescue StandardError => e
      Rails.logger.warn("[SpotSessionHold] Could not clear hold on session #{session.id}: #{e.message}")
    end

    # @param session [Session]
    # @return [Record, nil] nil when this session carries no hold record.
    def record_for(session)
      metadata = session.metadata || {}
      # Keyed on HELD_REASON, the same marker #held? reads. Keying this on
      # HELD_DETAIL instead would let the two disagree about whether a hold
      # exists, and a session #held? claims but #record_for denies is one the
      # sweep counts and then silently refuses to re-arm on every pass forever.
      return nil if metadata[HELD_REASON].blank?

      Record.new(
        detail: metadata[HELD_DETAIL],
        reason: metadata[HELD_REASON],
        turn: metadata[HELD_TURN],
        count: metadata[HELD_COUNT].to_i,
        held_at: parse_time(metadata[HELD_AT]),
        retry_at: parse_time(metadata[HELD_RETRY_AT])
      )
    end

    # Whether this session is dormant on a hold — refused at the door, or before
    # its next turn, and sitting in `waiting` with nothing but its own re-check
    # coming for it.
    #
    # Deliberately the same shape as SpotSessionPause.paused?, and deliberately a
    # SEPARATE population from it: a pause carries `spot_pause_reason` and is
    # resumed by SpotCeilingSweepJob, a hold carries `spot_hold_reason` and is
    # resumed by its own re-check. Every caller that has to ask "is this session
    # asleep on purpose?" needs both questions, and asking only the pause one is
    # how a held session gets treated as stranded (AgentSessionJob's interrupt
    # recovery) or reported as absent (`get_spot_policy`).
    def held?(session)
      session.waiting? && (session.metadata || {})[HELD_REASON].present?
    end

    # Every session dormant on a hold, oldest hold first.
    #
    # A session that ALSO carries a ceiling pause or an auth-outage park is not in
    # this population. Those are counted and resumed by their own owners, so
    # counting them here would double-count them — and #rearm! refuses them, so a
    # surface that included them would promise a repair that never comes.
    def held_sessions
      Session
        .where(status: :waiting)
        .where("metadata->>? IS NOT NULL", HELD_REASON)
        .where("metadata->>? IS NULL", SpotSessionPause::PAUSED_REASON)
        .where("metadata->>? IS NULL", AUTH_OUTAGE_REASON_KEY)
        .order(Arel.sql("metadata->>'spot_hold_at' ASC NULLS FIRST"))
    end

    # The standing population of sessions the gate has refused and not yet let
    # through — the number /inference and `get_spot_policy` report beside the paused
    # one.
    #
    # NOT the same figure as SpotSessionPause.paused_count, and not a subset of
    # it. That one counts sessions the `spot_budget` ceiling interrupted MID-RUN;
    # this one counts sessions refused BEFORE a turn. They have different resume
    # owners, so a surface that prints one of them under a label covering both
    # reports a deployment holding session 7507 as "asleep in the spot queue: 0".
    def held_count
      held_sessions.count
    rescue ActiveRecord::ActiveRecordError
      0
    end

    # The held sessions whose ladder has stalled: past their own re-check time by
    # more than the grace, and therefore waiting on nothing.
    #
    # A STRING comparison, not a cast. `spot_hold_retry_at` is written by #hold!
    # as a UTC ISO-8601 stamp, and those sort lexicographically in exactly
    # timestamp order — so `<` answers "is this in the past" without a
    # `::timestamptz`, which would raise on the whole query if any one row's
    # stamp were unparseable and take the /inference card down with it. Filtering
    # here rather than in Ruby also keeps this off the page's hot path: /inference
    # asks for the count on every render, and the alternative loads every dormant
    # session's row — `metadata` included, which now carries deferred prompts.
    def overdue_sessions(now: Time.current, grace: OVERDUE_GRACE)
      held_sessions.where("metadata->>? < ?", HELD_RETRY_AT, (now - grace).utc.iso8601)
    end

    def overdue_count(now: Time.current, grace: OVERDUE_GRACE)
      overdue_sessions(now: now, grace: grace).count
    rescue ActiveRecord::ActiveRecordError
      0
    end

    # === Repairing a stalled ladder ===

    # One pass: put every held session whose re-check never fired back on the
    # ladder.
    #
    # == Why a sweep has to exist
    #
    # A hold is a promise ("re-checking at 02:43:15") kept by exactly one thing:
    # the delayed job the hold enqueued. Each re-check forges the next link, so
    # the chain has no redundancy anywhere along it — lose one link and the
    # session waits forever, in a state that looks identical to a session merely
    # queued. Nothing else picks it up: SpotCeilingSweepJob only resumes the
    # `spot_pause_*` population, the quota-recovery wake only reads auth-outage
    # parks, and a start-held session has no runtime session to restart.
    #
    # That is not hypothetical. Session 7507 (tadasant/zimmer#648):
    #
    #   02:12:25  a re-check begins
    #   02:12:30  hold #145 COMMITS — `spot_hold_retry_at: 02:43:15`
    #   02:12:53  the worker is gone; GoodJob re-picks the row and raises
    #             InterruptError. The hold's own log line never reached the
    #             database, because it was still in the LogBuffer — which is how
    #             we know the execution died between the metadata write and the
    #             flush, taking the un-enqueued re-check with it.
    #   02:43:15  nothing happens, and nothing ever will.
    #
    # It was still sitting there eleven hours later, holding a fossilised "5 of 5
    # session slots taken" in front of a human while the live gate said 1 of 5.
    #
    # So the ladder's next rung stops depending on one job surviving: the DURABLE
    # record is `spot_hold_retry_at` on the session, and this sweep reconciles it
    # against reality every five minutes. A hold that is past due with no job
    # behind it gets a new one.
    #
    # == Not racing a re-check that is merely late
    #
    # Two guards, because a duplicated turn is a real cost. A hold has to be
    # OVERDUE_GRACE past due before it counts as stalled, and a session with an
    # unfinished AgentSessionJob against it is left alone — the job is queued and
    # running late, which is a busy worker rather than a broken ladder.
    #
    # Never raises. It runs on a cron beside everything else, and the condition is
    # re-read from scratch five minutes later, so a failed pass costs a pass.
    #
    # @return [Sweep]
    def sweep!(logger: nil)
      logger ||= StructuredLogger.new({ service: "SpotSessionHold" })
      overdue = overdue_count
      return Sweep.new(rearmed: 0, overdue: 0, skipped: 0, deferred: 0) if overdue.zero?

      stalled = overdue_sessions.limit(MAX_LOADED_PER_SWEEP).to_a
      queued = PendingAgentTurns.for(stalled.map(&:id))
      candidates, skipped = stalled.partition { |session| queued.exclude?(session.id) }

      # Dropped BEFORE the batch is taken, not inside #rearm!, and that ordering
      # is what stops the sweep starving. A session dormant for a reason that
      # outranks the hold is refused every pass and never advances its stamp, so
      # it stays overdue forever — and `held_sessions` orders oldest-hold-first,
      # which walks exactly those sessions to the head of the queue. Refusing them
      # only under the lock would let ten of them occupy the whole batch and keep
      # the sweep from ever reaching a genuinely stranded session, which is the
      # failure this job exists to prevent. The under-lock check stays as the race
      # guard.
      candidates, blocked = candidates.partition { |session| !dormant_for_another_reason?(session) }

      batch = candidates.first(MAX_REARMS_PER_SWEEP)
      deferred = overdue - skipped.size - batch.size

      logger.info("Held spot sessions are past their own re-check time",
        overdue: overdue, with_a_job_still_queued: skipped.size,
        dormant_for_another_reason: blocked.size, in_this_batch: batch.size)

      rearmed = batch.count { |session| rearm!(session, logger) }

      Sweep.new(rearmed: rearmed, overdue: overdue, skipped: skipped.size, deferred: deferred)
    rescue StandardError => e
      logger.warn("Spot hold sweep failed", error: "#{e.class}: #{e.message}")
      Sweep.new(rearmed: 0, overdue: 0, skipped: 0, deferred: 0)
    end

    private

    # Put one stranded session back on the ladder.
    #
    # The re-arm is a re-check, not an admission: it enqueues the same turn the
    # lost job was carrying and lets the gate decide again. If the gate is open
    # the session runs; if it is still closed the session is held again, with a
    # fresh re-check job behind it. Either way it stops waiting on nothing.
    #
    # `spot_hold_retry_at` is advanced BEFORE the job is enqueued and under the
    # row lock, so the stamp is the sweep's own idempotency key: the next pass
    # five minutes from now reads a re-check in the future and leaves the session
    # alone.
    def rearm!(session, logger)
      record = record_for(session)
      return false if record.nil?

      delay = rand(REARM_SPREAD.to_i).seconds
      retry_at = Time.current + delay
      # Only a String is a prompt. `enqueue_with_prompt` raises ArgumentError on
      # anything else, and it would raise AFTER the stamp was advanced — so the
      # session would re-arm, fail, and repeat every pass with no job. Anything
      # unusable falls back to the recovery nudge below.
      metadata = session.metadata || {}
      held_prompt = metadata[HELD_PROMPT]
      prompt = held_prompt.is_a?(String) ? held_prompt.presence : nil

      rearmed = false
      ActiveRecord::Base.transaction do
        session.lock!
        # Re-asked under the lock. A re-check that fired between #sweep!'s read
        # and this write has already advanced the ladder, and re-arming on top of
        # it would put a second job against the same turn.
        raise ActiveRecord::Rollback unless held?(session) &&
          record_for(session)&.overdue?(grace: OVERDUE_GRACE) &&
          !dormant_for_another_reason?(session)

        session.merge_metadata!(HELD_RETRY_AT => retry_at.utc.iso8601)
        rearmed = true
      end
      return false unless rearmed

      # The job first, the sentence about it second. A log line written ahead of a
      # failed enqueue is a session timeline promising a re-check that does not
      # exist — the fossil-read-as-live-state this whole class is about.
      images = files = nil
      carrying = ""
      if record.resuming?
        # Replayed off the hold RECORD, never off the volume. The record names
        # the attachments this turn was deferred with; the volume holds every
        # attachment the session has ever received, so reading it here would put
        # a screenshot an earlier turn already consumed onto this one — which is
        # silently wrong rather than silently incomplete (#890, and HELD_IMAGES).
        #
        # Tied to the real prompt on purpose. The recovery nudge below is a
        # different turn — Zimmer's own sentence about a stalled ladder — and
        # attachments belong to the prompt that referred to them, not to whatever
        # turn happens to run next.
        if prompt.present?
          images = still_on_the_volume(
            Sessions::AttachmentDescriptors.for_a_job(
              metadata[HELD_IMAGES], keys: Sessions::AttachmentDescriptors::IMAGE_KEYS
            ),
            ImageStorageService.new(session_id: session.id)
          )
          files = still_on_the_volume(
            Sessions::AttachmentDescriptors.for_a_job(
              metadata[HELD_FILES], keys: Sessions::AttachmentDescriptors::FILE_KEYS
            ),
            FileStorageService.new(session_id: session.id)
          )
          # Only the sentence is borrowed from the first-turn reader — the log
          # line a human reads must word this the same way whichever branch
          # carried the turn. The volume read that class exists for stays out of
          # this branch.
          carrying = Sessions::FirstTurnAttachments.carrying_clause(Array(images), Array(files))
        end

        AgentSessionJob.enqueue_with_prompt(
          session.id,
          prompt || AutomatedPrompts.system_recovery(
            reason: "Zimmer's spot-hold sweep found this session's re-check had stopped firing"
          ),
          images: images,
          files: files,
          delay: delay
        )
      else
        # The lost job carried this turn's images and files as arguments, and
        # AgentSessionJob reads them from nowhere else — so a bare re-arm brought
        # back "here is the screenshot, fix this" with the prompt and without the
        # screenshot (#789), under a log line claiming the turn had been carried
        # across. Re-read from the volume, where they sit keyed by session id.
        #
        # The volume, and not the hold record, because a START hold has no
        # record to read: `hold!` writes HELD_TURN_KEYS only for a resume, since
        # a first turn's prompt lives on the session row already. The two
        # branches recover the same thing from the two different places it
        # honestly survives in.
        #
        # `session_id.blank?` is the same predicate Sessions::StartNow uses for
        # "has never run", and it is what makes the volume the right place to
        # look: the gate holds a session BEFORE AgentSessionJob stamps a
        # session_id, so a genuine first start (and a restart from scratch, which
        # clears it) reads blank. On a session that HAS run, everything on the
        # volume belongs to turns it has already had, so the read is refused.
        #
        # That refusal is deliberately blunt and costs one narrow case, named
        # rather than hidden: McpOauthResumeService gates its own attachment
        # replay on a blank TRANSCRIPT, not a blank session_id, so it can put
        # attachments on a new-session job for a session that already has one.
        # A held-then-lost job of that shape is re-armed without them. Its
        # population is the intersection of four unlikely things, and reading the
        # volume to cover it would mis-attach on every other session that has
        # run — the trade #789 already made.
        if session.session_id.blank?
          images, files = Sessions::FirstTurnAttachments.for(session)
          carrying = Sessions::FirstTurnAttachments.carrying_clause(images, files)
        end
        AgentSessionJob.enqueue_new_session(
          session.id, images: images.presence, files: files.presence, delay: delay
        )
      end

      carried = if !record.resuming?
        "The turn it was holding is carried with it#{carrying}."
      elsif prompt.present?
        "The prompt it was holding is carried with it#{carrying}."
      else
        "The prompt it was woken for was lost with the re-check, so it comes back on a " \
        "recovery nudge instead."
      end

      session.logs.create!(
        level: "warning",
        content: "The re-check this spot hold promised (#{record.retry_at&.utc&.iso8601 || "unknown"}) " \
                 "never fired, so the session was waiting on nothing. Zimmer's spot-hold sweep put it " \
                 "back on the ladder: re-checking at #{retry_at.utc.iso8601}. #{carried}"
      )

      logger.info("Re-armed a stalled spot hold",
        session_id: session.id, holds: record.count, carried_prompt: prompt.present?,
        carried_attachments: Array(images).size + Array(files).size)
      true
    rescue StandardError => e
      logger.warn("Could not re-arm a stalled spot hold",
        session_id: session.id, error: "#{e.class}: #{e.message}")
      false
    end

    # The subset of a replayed record whose BYTES are still there.
    #
    # The record outlives the files it names. A hold can sit for an hour, and the
    # sweep re-arms records nobody has touched for far longer than that, while
    # `DurableSessionStorage`'s cleanup reaps a session's attachment tree on its
    # own schedule. Handing the adapter a path that is gone is not a missing
    # screenshot: ClaudeCliAdapter#load_image_as_base64 `binread`s it, the
    # Errno::ENOENT surfaces as a failed spawn, and AgentSessionJob stamps
    # `spawn_failed` and FAILS the session. Losing an attachment is the cost this
    # class was already paying; losing the turn is not, and a repair path must
    # not be able to do more damage than the thing it repairs.
    #
    # The START branch gets this for free — it reads what is on disk. This is the
    # resume branch buying the same guarantee for a record it read from a row.
    #
    # An unreadable volume degrades to "no attachments", deliberately and in the
    # same direction: a turn short an attachment still runs.
    #
    # @return [Array<Hash>, nil] nil rather than [], so it passes straight to an
    #   `images:` keyword that means "none" by absence
    def still_on_the_volume(descriptors, storage)
      return nil if descriptors.blank?

      descriptors.select { |descriptor| storage.exists?(descriptor[:path]) }.presence
    rescue StandardError => e
      Rails.logger.warn(
        "[SpotSessionHold] Could not confirm a replayed attachment for session " \
        "#{storage.session_id}: #{e.class}: #{e.message}"
      )
      nil
    end

    # Whether something OTHER than the hold is why this session is asleep. A
    # ceiling pause, an auth-outage park and a wall-clock pause each own their own
    # resume, and re-arming underneath one of them would start a session its owner
    # deliberately stopped.
    def dormant_for_another_reason?(session)
      SpotSessionPause.paused?(session) ||
        AuthOutageParkService.parked?(session) ||
        session.paused_until_scheduled_time?
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Whether this decision refuses this turn. Every hold reason refuses a session
    # that holds no slot; a session already counted in the running fleet is
    # refused only by the utilization reading.
    def applies_to?(decision, session)
      return true unless session.running?

      RUNNING_HOLD_REASONS.include?(decision.reason)
    end

    def hold!(session, decision, follow_up_prompt:, log_buffer:, images:, files:)
      resuming = follow_up_prompt.present?
      metadata = session.metadata || {}

      # Normalized ONCE, at the door, and every carrier below is built from the
      # result. This method hands the same turn's attachments to as many as three
      # different places — the delayed job, the durable hold record, and the
      # enqueued-message queue — and building them from different values is
      # precisely how two copies of one turn come to disagree. A descriptor the
      # adapters cannot read (`image[:path]` against a string-keyed hash) is the
      # failure this class is fixing, wearing the other face.
      images = Sessions::AttachmentDescriptors.for_a_job(
        images, keys: Sessions::AttachmentDescriptors::IMAGE_KEYS
      )
      files = Sessions::AttachmentDescriptors.for_a_job(
        files, keys: Sessions::AttachmentDescriptors::FILE_KEYS
      )

      # Read BEFORE this hold overwrites it: a re-check still in the future means
      # an earlier deferral already has a job scheduled to carry a turn. This
      # prompt goes behind that turn rather than racing it, and the hold record is
      # left exactly as that deferral wrote it — the re-check it promises is the
      # one that will actually fire, and this is not another rung on the ladder.
      if resuming && (scheduled_at = scheduled_turn_at(metadata))
        queue_behind_scheduled_turn(session, follow_up_prompt, scheduled_at,
                                    images: images, files: files, log_buffer: log_buffer)
        # Custody again, and here it is the whole point: the marker this delivery
        # stamped names a prompt that is now in the queue, and the job already
        # scheduled prefers the marker over its own argument. Left in place it
        # would deliver this prompt twice and the earlier one never.
        session.remove_metadata!(%w[pending_follow_up_prompt pending_follow_up_sent_at])
        return_to_queue!(session)
        return
      end

      count = metadata[HELD_COUNT].to_i + 1
      delay = retry_delay(decision, count)
      retry_at = Time.current + delay

      # The deferred turn, in the shape it has to come back out of jsonb in. The
      # prompt and its attachments are written together because they ARE one
      # turn: a re-arm that replayed the prompt of this hold and the screenshot
      # of the last one would be worse than replaying neither.
      held_turn = if resuming
        {
          HELD_PROMPT => follow_up_prompt,
          HELD_IMAGES => Sessions::AttachmentDescriptors.for_the_record(
            images, keys: Sessions::AttachmentDescriptors::IMAGE_KEYS
          ),
          HELD_FILES => Sessions::AttachmentDescriptors.for_the_record(
            files, keys: Sessions::AttachmentDescriptors::FILE_KEYS
          )
        }.compact
      else
        {}
      end


      # One statement, and it drops the delivery marker in the same breath. The gate
      # is taking custody of this prompt — see the class comment — but only when it
      # actually holds one: a promptless hold that dropped the marker would discard
      # a prompt nothing else is carrying.
      session.merge_metadata!(
        {
          # UTC, for the same reason SpotSessionPause#pause! writes UTC: both of
          # these stamps are compared and ordered LEXICOGRAPHICALLY as stored
          # strings (see #held_sessions and #overdue_sessions), and an offset
          # rendering would sort into the wrong place.
          HELD_AT => Time.current.utc.iso8601,
          HELD_REASON => decision.reason,
          HELD_DETAIL => decision.detail,
          HELD_RETRY_AT => retry_at.utc.iso8601,
          HELD_COUNT => count,
          HELD_TURN => resuming ? TURN_RESUME : TURN_START
          # The turn goes on the row as well as on the job. Custody without a
          # durable copy is how a turn gets lost: the job is the only carrier, and
          # a worker that dies before the enqueue below takes the prompt — and
          # every attachment that came with it — along with it.
        }.merge(held_turn),
        (resuming ? %w[pending_follow_up_prompt pending_follow_up_sent_at] : []) +
          (HELD_TURN_KEYS - held_turn.keys)
      )

      message = "Spot session held #{resuming ? 'before its next turn' : 'before starting'}: " \
                "#{decision.detail} " \
                "Re-checking at #{retry_at.iso8601} (hold ##{count}). " \
                "Its class was #{session.scheduling_class_source}. " \
                "Make this one session priority to start it now."
      log_buffer&.add(message, level: "warning")
      # A hold has to be readable in the session's own timeline, not only in the
      # metadata the banner renders. AgentSessionJob passes a buffer and flushes
      # it; a caller without one writes the line straight through rather than
      # dropping it.
      session.logs.create!(level: "warning", content: message) if log_buffer.nil?
      Rails.logger.info("[SpotSessionHold] Session #{session.id} held: #{decision.reason}")

      # The turn is DEFERRED, never dropped.
      if resuming
        AgentSessionJob.enqueue_with_prompt(
          session.id,
          follow_up_prompt,
          images: images,
          files: files,
          delay: delay
        )
      else
        AgentSessionJob.enqueue_new_session(
          session.id,
          images: images,
          files: files,
          delay: delay
        )
      end

      return_to_queue!(session)
    end

    # When an earlier deferral's re-check job is due, or nil if none is pending.
    #
    # `HELD_RETRY_AT` is written when a job is scheduled and is only ever in the
    # future while that job is pending — the re-check that fires AT it reads its
    # own stamp as already past. So a future stamp means "a job is coming", which
    # is exactly the condition under which a second job would be redundant.
    def scheduled_turn_at(metadata)
      retry_at = metadata[HELD_RETRY_AT]
      return nil if retry_at.blank?

      at = parse_time(retry_at)
      at if at.present? && at > Time.current
    end

    # Put a refused prompt into the session's durable message queue, behind the
    # turn already scheduled ahead of it. `drain_enqueued_messages_after_pause`
    # delivers it when that turn ends.
    def queue_behind_scheduled_turn(session, prompt, scheduled_at, images:, files:, log_buffer:)
      position = (session.enqueued_messages.maximum(:position) || 0) + 1
      session.enqueued_messages.create!(
        content: prompt,
        position: position,
        # A jsonb column, so the record shape — the same round trip the hold
        # record takes, and the one EnqueuedMessageProcessorService reads back.
        images: Array(Sessions::AttachmentDescriptors.for_the_record(
          images, keys: Sessions::AttachmentDescriptors::IMAGE_KEYS
        )),
        files: Array(Sessions::AttachmentDescriptors.for_the_record(
          files, keys: Sessions::AttachmentDescriptors::FILE_KEYS
        )),
        origin: origin_for(prompt)
      )
      message = "Spot session held before its next turn: a turn is already deferred to " \
                "#{scheduled_at.iso8601}, so this prompt was queued behind it (position " \
                "#{position}) rather than given a job of its own. Nothing is lost — it is " \
                "delivered when that turn ends."
      log_buffer&.add(message, level: "warning")
      session.logs.create!(level: "warning", content: message) if log_buffer.nil?
    rescue StandardError => e
      # Never lose the prompt to a queue failure: fall back to a job of its own,
      # which the concurrency guard may drop but which at least still carries it.
      Rails.logger.warn(
        "[SpotSessionHold] Could not queue a deferred prompt for session #{session.id}: #{e.class}: #{e.message}"
      )
      AgentSessionJob.enqueue_with_prompt(
        session.id, prompt, images: images, files: files,
        delay: SpotGateService::RETRY_DELAY
      )
    end

    # Who wrote the prompt this hold is parking in the queue.
    #
    # This method is the ONLY place a durable queue row is created from a prompt
    # the gate refused, and it is a funnel rather than a caller: a trigger fire, a
    # human follow-up and Zimmer's own recovery nudge all arrive here as the same
    # opaque string. Most of what it sees is somebody else's message and is
    # `caller`, which is the default and the wider bucket for exactly that reason.
    #
    # The one it can name is the recovery nudge. `AutomatedPrompts.system_recovery?`
    # is the same predicate AgentSessionJob already keys `resume_for_system_recovery!`
    # off, so this does not invent a second way to recognise the nudge — and reading
    # the body is confined to this one write. Every reader afterwards asks the
    # column.
    #
    # Getting this wrong in either direction is bounded and neither is silent: a
    # nudge mis-stamped `caller` pages the way it did before, and a caller's message
    # could only be mis-stamped by opening with the nudge template verbatim.
    #
    # That second direction is REACHABLE rather than impossible, and it is worth
    # saying so plainly. A follow-up sent to a spot-class session travels
    # deliver_follow_up! -> AgentSessionJob -> hold_if_needed -> here, so a caller
    # who opened their message with the whole template would have it stamped as
    # Zimmer's and would lose the page if that message were later stranded. Three
    # things bound it: the column itself is settable by no request (every create
    # site names its attributes literally, and no permit list mentions `origin`),
    # so this is a content collision rather than field injection; the only thing
    # the collision buys is silence about the collider's OWN discarded message;
    # and AgentSessionJob already keys `resume_for_system_recovery!` off this same
    # predicate, so recognising the nudge by its body is a mechanism this codebase
    # already relies on rather than one introduced here. Threading an explicit
    # origin down from each of the dozen senders would close it properly and is
    # the right shape if this ever needs to be airtight.
    def origin_for(prompt)
      if AutomatedPrompts.system_recovery?(prompt)
        "automated_recovery_nudge"
      elsif AutomatedPrompts.merge_conflict_pr_url(prompt).present?
        # Stamped so the delivery-time re-read can find it. A conflict notice
        # that reached a spot-class session while it was parked in `needs_input`
        # was SENT rather than queued, and lands back in the queue here when the
        # gate refuses the turn carrying it — where it can wait hours at the
        # quota wall rather than the minutes an ordinary turn boundary takes. It
        # is therefore the longest-gap version of the staleness this origin
        # exists to catch (EnqueuedMessage#stale?), and the one most likely to be
        # false by the time anybody reads it.
        "automated_merge_conflict"
      else
        "caller"
      end
    end

    # Put a session whose turn was refused into the dormant `waiting` state a held
    # session sits in. A no-op for the ordinary first start, which is already
    # there.
    #
    # It is not always there. A resume's deliverer has already flipped the session
    # to `running`, and so has every "restart from scratch" path — the Restart
    # button, `action_session`, `POST /api/v1/sessions/:id/restart` — which calls
    # `resume!` and only then enqueues the job. Leaving it in `running` is a lie
    # with consequences: it counts against the fleet cap, the session card claims
    # work is happening, and `CleanupOrphanedSessionsJob` reads "running with a
    # blank running_job_id" as DEFINITELY orphaned and reaps it on its next
    # five-minute pass, long before the ten-minute re-check the hold scheduled
    # (issue #589). `waiting` makes a deferred turn indistinguishable from a hold
    # at the starting line, which is exactly what it is.
    #
    # Deliberately NOT `pause!`. That event means "a turn ended and the session
    # wants a human": it fires the `session_needs_input` event triggers — waking
    # any parent watching this session — enqueues a push notification, and queues
    # a status-summary refresh. No turn ran here and no token was spent, so
    # announcing one would wake an orchestrator and page a person about work that
    # never happened.
    def return_to_queue!(session)
      if session.running?
        session.update!(status: :waiting, running_job_id: nil)
      elsif session.needs_input? && session.may_sleep?
        session.update!(running_job_id: nil) if session.running_job_id.present?
        session.sleep!
      end
    rescue StandardError => e
      # The retry is already enqueued, so the turn is safe either way. A session
      # left `running` is wrong but not lost — the orphan sweep recovers it.
      Rails.logger.warn(
        "[SpotSessionHold] Could not return session #{session.id} to the spot queue: #{e.class}: #{e.message}"
      )
    end

    # How long this hold waits before re-checking.
    #
    # `count` is 1-based — the hold being recorded right now — so the first hold
    # takes no doubling and keeps the plain SpotGateService::RETRY_DELAY. The
    # jitter is added AFTER the ceiling so that a population pinned at the ceiling
    # still spreads out rather than re-checking in lockstep, which is the failure
    # the jitter existed for in the first place.
    def retry_delay(decision, count)
      steps = [ count - 1, MAX_BACKOFF_STEPS ].min
      base = SpotGateService::RETRY_DELAY * (2**steps)

      [ base, ceiling_for(decision) ].min + rand(RETRY_JITTER.to_i).seconds
    end

    def ceiling_for(decision)
      decision.reason == UTILIZATION_REASON ? UTILIZATION_MAX_RETRY_DELAY : FLEET_CAP_MAX_RETRY_DELAY
    end
  end
end
