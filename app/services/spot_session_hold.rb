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
# The refused prompt (with its images and files) rides the delayed job. Two
# things keep that honest when a session is held for the best part of an hour and
# something delivers to it again in the meantime — an orchestrator's second child
# waking it, say:
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

    private

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

      # One statement, and it drops the delivery marker in the same breath. The gate
      # is taking custody of this prompt — see the class comment — but only when it
      # actually holds one: a promptless hold that dropped the marker would discard
      # a prompt nothing else is carrying.
      session.merge_metadata!(
        {
          HELD_AT => Time.current.iso8601,
          HELD_REASON => decision.reason,
          HELD_DETAIL => decision.detail,
          HELD_RETRY_AT => retry_at.iso8601,
          HELD_COUNT => count,
          HELD_TURN => resuming ? TURN_RESUME : TURN_START
        },
        resuming ? %w[pending_follow_up_prompt pending_follow_up_sent_at] : []
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

    # When an earlier deferral's re-check job is due, or nil if none is pending.
    #
    # `HELD_RETRY_AT` is written when a job is scheduled and is only ever in the
    # future while that job is pending — the re-check that fires AT it reads its
    # own stamp as already past. So a future stamp means "a job is coming", which
    # is exactly the condition under which a second job would be redundant.
    def scheduled_turn_at(metadata)
      retry_at = metadata[HELD_RETRY_AT]
      return nil if retry_at.blank?

      at = Time.zone.parse(retry_at.to_s)
      at if at.present? && at > Time.current
    rescue ArgumentError, TypeError
      nil
    end

    # Put a refused prompt into the session's durable message queue, behind the
    # turn already scheduled ahead of it. `drain_enqueued_messages_after_pause`
    # delivers it when that turn ends.
    def queue_behind_scheduled_turn(session, prompt, scheduled_at, images:, files:, log_buffer:)
      position = (session.enqueued_messages.maximum(:position) || 0) + 1
      session.enqueued_messages.create!(
        content: prompt,
        position: position,
        images: Array(images),
        files: Array(files)
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
        session.id, prompt, images: images.presence, files: files.presence,
        delay: SpotGateService::RETRY_DELAY
      )
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
