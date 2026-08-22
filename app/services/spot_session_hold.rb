# frozen_string_literal: true

# Holds a spot session at the starting line when a quota window has reached its
# target or every session slot is taken, and re-queues it to try again.
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
# 5-hour target and force-pausing 22 running spot sessions. It was not far down
# the queue by accident; it never consulted the queue at all.
#
# So the gate is a choke point on turns. What still passes through spends
# nothing:
#
#   * `clone_only` — sets up a clone, spawns no agent.
#   * `resume_monitoring` — re-attaches to a process that is ALREADY running.
#     Holding it would orphan that process rather than save a token.
#
# And one hold reason does not apply to a resume: `fleet_at_cap`. A resuming
# session has already been flipped to `running` by whoever delivered the turn,
# so it is counted in `Session.running_claude_code_count` itself — refusing it
# for a full fleet would refuse it on the strength of its own slot, and would
# refuse every session SpotSessionPause resumes, which are flipped to `running`
# before their jobs run. The utilization reading has no such problem: the pool's
# windows are measured independently of this session.
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
  METADATA_KEYS = [ HELD_AT, HELD_REASON, HELD_DETAIL, HELD_RETRY_AT, HELD_COUNT, HELD_TURN ].freeze

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

  # The hold reasons that apply to a RESUME, as opposed to a first start. See the
  # class comment: a resuming session is already counted in the fleet, so only
  # the utilization reading can honestly refuse it.
  RESUME_HOLD_REASONS = [ UTILIZATION_REASON ].freeze

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
      if decision.allowed? || !applies_to?(decision, follow_up_prompt)
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

    private

    # Whether this decision refuses this shape of turn. A first start is refused
    # by every hold reason; a resume only by the utilization reading.
    def applies_to?(decision, follow_up_prompt)
      return true if follow_up_prompt.blank?

      RESUME_HOLD_REASONS.include?(decision.reason)
    end

    def hold!(session, decision, follow_up_prompt:, log_buffer:, images:, files:)
      resuming = follow_up_prompt.present?
      metadata = session.metadata || {}
      count = metadata[HELD_COUNT].to_i + 1
      delay = retry_delay(decision, count)
      retry_at = Time.current + delay

      session.update_columns(
        metadata: metadata.merge(
          HELD_AT => Time.current.iso8601,
          HELD_REASON => decision.reason,
          HELD_DETAIL => decision.detail,
          HELD_RETRY_AT => retry_at.iso8601,
          HELD_COUNT => count,
          HELD_TURN => resuming ? TURN_RESUME : TURN_START
        )
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

      # The turn is DEFERRED, never dropped. A wake that arrived as a prompt is
      # re-enqueued with that prompt and its attachments, so the delayed job
      # GoodJob persists is a complete replacement for the turn being refused —
      # nothing else has to remember it.
      if resuming
        AgentSessionJob.enqueue_with_prompt(
          session.id,
          follow_up_prompt,
          images: images.presence,
          files: files.presence,
          delay: delay
        )
      else
        AgentSessionJob.enqueue_new_session(
          session.id,
          images: images.presence,
          files: files.presence,
          delay: delay
        )
      end

      return_to_queue!(session)
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
