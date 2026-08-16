# frozen_string_literal: true

# Holds a spot session at the starting line when the fleet is already at the
# concurrency the quota can carry, and re-queues it to try again.
#
# A held session is left in `waiting` — Zimmer's existing "created, not started"
# status — and AgentSessionJob is re-enqueued with a delay. GoodJob persists a
# delayed job in Postgres, so the retry survives a worker restart or a deploy;
# nothing depends on this process staying alive.
#
# The delay is one control interval plus a little jitter. Without the jitter a
# backlog held in the same minute re-checks in the same minute forever, and every
# one of them reads the same fleet size before any of them has started — so the
# whole queue would either stampede past capacity together or wait together.
#
# The hold is recorded in `metadata` so the session detail page can explain
# itself rather than looking mysteriously stuck, and a log line lands in the
# session's own log for the same reason.
#
# == The starvation floor
#
# A window that stays at its ceiling holds spot work for as long as it stays
# there, and nothing in the forecast bounds that: production ran a session
# waiting 23 hours. So a session held past STARVATION_DEADLINE is let through
# once the fleet is empty. Both halves matter — the deadline is what guarantees
# the queue eventually moves, and the empty fleet is what keeps that guarantee
# from becoming a second, unbudgeted way to run work while the deployment is
# already busy.
#
# Only the FIRST start of a session is gated. A follow-up, a monitoring resume
# and a clone-only setup all pass straight through: interrupting a conversation
# that is already underway strands work half-done and wastes the tokens already
# spent on it, which is the opposite of what a quota gate is for. The decision
# point that means something is "should this work begin at all".
class SpotSessionHold
  HELD_AT = "spot_hold_at"
  HELD_SINCE = "spot_hold_since"
  HELD_REASON = "spot_hold_reason"
  HELD_DETAIL = "spot_hold_detail"
  HELD_RETRY_AT = "spot_hold_retry_at"
  HELD_COUNT = "spot_hold_count"

  METADATA_KEYS = [ HELD_AT, HELD_SINCE, HELD_REASON, HELD_DETAIL, HELD_RETRY_AT, HELD_COUNT ].freeze

  # How long a session may be held before the floor lets it through.
  STARVATION_DEADLINE = 2.hours

  # Spread over which held sessions re-check, so a backlog does not re-evaluate
  # in lockstep.
  RETRY_JITTER = 2.minutes

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
      # readable predicate and the production path cannot drift apart — and
      # start_decision counts the candidate session, which the argument-free
      # `evaluate` (the informational reading) does not.
      decision = SpotGateService.start_decision(session)
      if decision.allowed?
        clear(session)
        return false
      end

      if starved?(session)
        release_starved(session, decision, log_buffer: log_buffer)
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

    # When this session was first held, or nil if it never has been.
    def held_since(session)
      raw = (session.metadata || {})[HELD_SINCE]
      return nil if raw.blank?

      Time.zone.parse(raw.to_s)
    end

    private

    # Held longer than the deadline, with nothing running to spend against. The
    # fleet check is what stops the floor from admitting the entire backlog at
    # once the moment it goes stale.
    def starved?(session)
      since = held_since(session)
      return false if since.nil? || Time.current - since < STARVATION_DEADLINE

      ClaudeUsageRateService.active_session_count.zero?
    end

    def release_starved(session, decision, log_buffer:)
      waited = ((Time.current - held_since(session)) / 3600.0).round(1)
      message = "Spot session released after #{waited}h held (#{decision.reason}): nothing is running, " \
                "and a spot session is deferred work, not abandoned work. #{decision.detail}"
      log_buffer&.add(message, level: "warning")
      Rails.logger.info("[SpotSessionHold] Session #{session.id} released by the starvation floor after #{waited}h")

      clear(session)
    end

    def hold!(session, decision, log_buffer:, images:, files:)
      delay = SpotGateService::CONTROL_INTERVAL + rand(RETRY_JITTER.to_i).seconds
      retry_at = Time.current + delay
      metadata = session.metadata || {}
      count = metadata[HELD_COUNT].to_i + 1

      session.update_columns(
        metadata: metadata.merge(
          HELD_AT => Time.current.iso8601,
          # First hold wins: this is what the starvation floor measures against,
          # so re-holding must not keep resetting the clock.
          HELD_SINCE => metadata[HELD_SINCE].presence || Time.current.iso8601,
          HELD_REASON => decision.reason,
          HELD_DETAIL => decision.detail,
          HELD_RETRY_AT => retry_at.iso8601,
          HELD_COUNT => count
        )
      )

      message = "Spot session held for quota headroom: #{decision.detail} " \
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
  end
end
