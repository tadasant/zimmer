# frozen_string_literal: true

module WorkBacklog
  # Hold one stranded row for a human decision. The one write behind the MCP tool,
  # the REST action and the Issues page's form, so the three cannot disagree about
  # which rows may be held. See WorkBacklogItem::HOLD_DURATION for what a hold is
  # and why it lapses.
  #
  # THE REFUSALS ARE THE POINT. A hold takes a row out of the population that
  # pages, so each one below closes a way to silence a row that should still page:
  #
  #   * a row that is not stranded — a queued, in-flight or resolved row has
  #     nothing for a hold to say, and holding it would pre-silence it for the
  #     day it strands;
  #   * a row whose evidence has not been read (no liveness state, or `unknown`)
  #     — the hold records the evidence it stands on, and there is none;
  #   * a row already held — a hold is not extended in place. When it lapses the
  #     row pages, and a triager re-reads it before holding it again.
  class Hold
    class Refused < StandardError; end

    # @param item [WorkBacklogItem]
    # @param reason [String] the decision owed, in words
    # @param by [String] who is recording it
    # @param session [Session, nil] the recording session, for provenance
    # @return [WorkBacklogItem] the held row
    def self.call(item:, reason:, by:, session: nil, now: Time.current)
      reason = reason.to_s.strip
      raise Refused, "reason is required: say which decision is owed, and by whom" if reason.empty?
      if reason.length > WorkBacklogItem::HOLD_REASON_MAX
        raise Refused, "reason is too long (#{reason.length} characters; the limit is #{WorkBacklogItem::HOLD_REASON_MAX})"
      end

      item.with_lock do
        unless WorkBacklogItem.unresolved(now: now).exists?(id: item.id)
          raise Refused, "#{item.key} (row #{item.id}) is not stranded — only a row that left the queue " \
                         "and is still unresolved can be held for a decision"
        end
        if item.liveness_state.nil? || item.liveness_state == WorkBacklogItem::LIVENESS_UNKNOWN
          raise Refused, "#{item.key} (row #{item.id}) has no liveness evidence yet " \
                         "(#{item.liveness_state || 'not checked'}); a hold records the evidence it stands on, " \
                         "so wait for the next WorkBacklogLivenessSweepJob pass"
        end
        if item.hold_active?(now: now)
          raise Refused, "#{item.key} (row #{item.id}) is already held until #{item.held_until.iso8601}. " \
                         "A hold is not extended: when it lapses the row pages again, which is the reminder"
        end

        item.hold_for_decision!(reason: reason, by: by, session: session, now: now)
      end

      item
    end
  end
end
