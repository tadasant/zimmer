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
# into a decaying one.
#
# The ceiling depends on WHY the session is held, because the two reasons clear
# on very different timescales. A utilization hold waits on a quota window coming
# back down, which takes hours; a fleet-cap hold waits on any running session
# finishing, which can happen at any moment. Backing both off to the same ceiling
# would either leave the utilization case re-checking pointlessly or make the
# fleet-cap case sluggish, so they get different ones.
#
# The cost is disclosed rather than hidden: a session can now sleep longer than
# it strictly had to — up to its ceiling — if the condition clears early. That is
# bounded (an hour at worst), visible on the session page via HELD_RETRY_AT, and
# a human who wants it now can make the one session priority, which the hold
# message already says.
#
# The hold is recorded in `metadata` so the session detail page can explain
# itself rather than looking mysteriously stuck, and a log line lands in the
# session's own log for the same reason.
#
# Only the FIRST start of a session is gated. A follow-up, a monitoring resume
# and a clone-only setup all pass straight through: interrupting a conversation
# that is already underway strands work half-done and wastes the tokens already
# spent on it, which is the opposite of what a quota gate is for. The decision
# point that means something is "should this work begin at all".
class SpotSessionHold
  HELD_AT = "spot_hold_at"
  HELD_REASON = "spot_hold_reason"
  HELD_DETAIL = "spot_hold_detail"
  HELD_RETRY_AT = "spot_hold_retry_at"
  HELD_COUNT = "spot_hold_count"

  METADATA_KEYS = [ HELD_AT, HELD_REASON, HELD_DETAIL, HELD_RETRY_AT, HELD_COUNT ].freeze

  # Spread over which held sessions re-check, so a backlog does not re-evaluate
  # in lockstep.
  RETRY_JITTER = 2.minutes

  # Consecutive holds double the re-check interval from SpotGateService::RETRY_DELAY:
  # 10m, 20m, 40m, and on up to the ceiling for the hold's reason. Clamped so a
  # session held for days cannot turn `2 ** steps` into a number no ceiling has to
  # reason about; the ceilings below are what actually bound the delay.
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

  class << self
    # True when the session was held and the caller should stop. False means
    # carry on and start it.
    #
    # @param session [Session]
    # @param log_buffer [LogBuffer, nil]
    # @param images [Array<Hash>, nil] carried through to the retry unchanged
    # @param files [Array<Hash>, nil]
    def hold_if_needed(session, log_buffer: nil, images: nil, files: nil)
      return false unless session.spot?

      # The one seam. SpotGateService.allow_start? reads the same method, so the
      # readable predicate and the production path cannot drift apart.
      decision = SpotGateService.start_decision(session)
      if decision.allowed?
        clear(session)
        return false
      end

      hold!(session, decision, log_buffer: log_buffer, images: images, files: files)
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

    def hold!(session, decision, log_buffer:, images:, files:)
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
          HELD_COUNT => count
        )
      )

      message = "Spot session held: #{decision.detail} " \
                "Re-checking at #{retry_at.iso8601} (hold ##{count}). " \
                "Its class was #{session.scheduling_class_source}. " \
                "Make this one session priority to start it now."
      log_buffer&.add(message, level: "warning")
      Rails.logger.info("[SpotSessionHold] Session #{session.id} held: #{decision.reason}")

      AgentSessionJob.enqueue_new_session(
        session.id,
        images: images.presence,
        files: files.presence,
        delay: delay
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
