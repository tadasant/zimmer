# frozen_string_literal: true

# Holds a spot session at the starting line when the forecast says there is no
# headroom, and re-queues it to try again.
#
# A held session is left in `waiting` — Zimmer's existing "created, not started"
# status — and AgentSessionJob is re-enqueued with a delay. GoodJob persists a
# delayed job in Postgres, so the retry survives a worker restart or a deploy;
# nothing depends on this process staying alive.
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
      # `evaluate` (the informational reading for /settings) does not.
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
      retry_at = Time.current + SpotGateService::RETRY_DELAY
      count = (session.metadata || {})[HELD_COUNT].to_i + 1

      session.update_columns(
        metadata: (session.metadata || {}).merge(
          HELD_AT => Time.current.iso8601,
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
        delay: SpotGateService::RETRY_DELAY
      )
    end
  end
end
