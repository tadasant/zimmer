# frozen_string_literal: true

module Sessions
  # Whether a session may be archived over the messages still queued for it, and
  # what to say to the caller when it may not.
  #
  # Archiving ends every path by which a queued message could be delivered:
  # EnqueuedMessageProcessorService claims `pending` rows only, and the only
  # thing that claims them for a live session is AgentSessionJob's end-of-turn
  # drain, which an archived session never reaches. So an archive over a
  # non-empty queue is a discard, and `Session#strand_pending_enqueued_messages`
  # retires the rows to `undelivered` to record it.
  #
  # Recording the discard is not the same as intending it. An agent
  # self-archives because it believes its work is done, and a message that
  # landed mid-turn is exactly the evidence that the belief is stale — so the
  # archive is refused, and the caller is told to let the message arrive
  # instead. `force` is the deliberate override for a caller that has read the
  # message and is choosing to discard it anyway.
  #
  # **Consulted by caller-facing surfaces only** — the MCP tool, the REST API,
  # the web UI. System-initiated archives (HealthMonitorService's stale sweep,
  # status-summary fork cleanup, SessionStatusSummaryHarvestJob) deliberately do
  # NOT consult it and archive unconditionally. That asymmetry is the point: a
  # refusal those callers could hit would be a fleet-wide stuck state with no
  # human in the loop to clear it, and none of them is a caller that could
  # reconsider. Their discards are still recorded by the retirement callback,
  # which runs on the transition itself and so covers every path.
  module ArchiveGuard
    module_function

    # The messages an archive of +session+ would discard.
    #
    # @param session [Session]
    # @return [Array<EnqueuedMessage>] ordered, possibly empty
    def pending_messages(session)
      session.enqueued_messages.pending.ordered.to_a
    end

    # @param session [Session]
    # @return [Boolean] whether archiving would discard anything
    def blocked?(session)
      pending_messages(session).any?
    end

    # The refusal an agent or API caller reads.
    #
    # Leads with what not to do, because for the caller that hits this most —
    # a session archiving itself at the end of a turn — not archiving is free
    # and correct: the pause drains the queue, the message arrives as the next
    # turn, and the archive succeeds after that because the queue is empty.
    # `force` is named last and hedged, so it reads as the exception it is.
    #
    # @param session [Session]
    # @param messages [Array<EnqueuedMessage>]
    # @return [String]
    def refusal_message(session, messages)
      previews = messages.map { |message| "  #{message.position}. #{message.content.to_s.truncate(160)}" }

      [
        "Cannot archive session #{session.id}: #{message_count(messages)} " \
        "#{messages.one? ? 'has' : 'have'} not been delivered. Archiving discards #{messages.one? ? 'it' : 'them'}.",
        "",
        *previews,
        "",
        "Do not archive. If you are this session, end your turn instead — the queued message is delivered as " \
        "your next turn, and archiving after that succeeds because the queue is empty. If you are archiving " \
        "another session, leave it alone and let it consume what you sent it.",
        "",
        "Only if you have read the message above and are deliberately discarding it: re-call with " \
        "\"force\": true. That is not the recommended path — the message was accepted from someone who was " \
        "told it would be delivered, and forcing throws it away."
      ].join("\n")
    end

    # The one-line version, for a human surface that shows the queue alongside it.
    #
    # @param messages [Array<EnqueuedMessage>]
    # @return [String]
    def summary(messages)
      "This session has #{message_count(messages)} that #{messages.one? ? 'has' : 'have'} not been delivered. " \
      "Archiving discards #{messages.one? ? 'it' : 'them'}."
    end

    # @param messages [Array<EnqueuedMessage>]
    # @return [String]
    def message_count(messages)
      messages.one? ? "1 queued message" : "#{messages.size} queued messages"
    end
  end
end
