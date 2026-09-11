# frozen_string_literal: true

module Sessions
  # Whether a session may be archived over the messages still queued for it, and
  # what to say to the caller when it may not.
  #
  # Archiving ends every path by which a queued message could be delivered.
  # EnqueuedMessageProcessorService claims `pending` rows only, and every caller
  # that claims them runs off a live session's turn — AgentSessionJob's
  # end-of-turn drain, SessionRecoveryService, SessionContinuation,
  # Sessions::InterruptService. An archived session reaches none of them. So an
  # archive over a non-empty queue is a discard, and
  # `Session#strand_pending_enqueued_messages` retires the rows to `undelivered`
  # to record it.
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
    # Raised by guarded_archive! when messages are queued and the caller did not
    # force. Carries them, so the surface can render its own refusal.
    class Refused < StandardError
      attr_reader :messages

      def initialize(messages)
        @messages = messages
        super("#{messages.size} queued message(s) would be discarded")
      end
    end

    module_function

    # Archive +session+ unless that would discard a queued message, with the
    # check and the transition under one row lock.
    #
    # THE DEFECT THIS EXISTS FOR (#1139). Every surface used to read the queue
    # unlocked and then call `archive!`. A wake that committed a pending row in
    # between was neither refused nor delivered: the archive's retirement
    # callback found it, stranded it, and paged. Production session 16494 hit it
    # at 10:47:02Z on 2026-09-11, when a held backstop wake came due in the same
    # second its woken turn self-archived.
    #
    # The lock is the session row, taken `FOR UPDATE`. That closes the window
    # against every enqueuer, not only the ones that lock the session themselves
    # (Trigger#follow_up_session!, EnqueuedMessageProcessorService): the insert's
    # foreign-key check takes `FOR KEY SHARE` on the same row, which `FOR UPDATE`
    # conflicts with. So an enqueue that committed first is read here and
    # refused, and one that arrives later waits for the archive to commit and
    # then meets an archived session.
    #
    # Held across `archive!` and its `after` callbacks, which run inside the
    # transition's transaction and already held this row from the status
    # `UPDATE` onwards. Taking it earlier adds no new lock ordering. The pages
    # and triggers in those callbacks are deferred to after commit, so they fire
    # once the lock is released.
    #
    # The block, if given, runs under the same lock after the queue check and
    # before the transition. It is where a surface puts its other refusals —
    # the live-turn one — so they cannot come ahead of this one: a caller told
    # about the live turn first would send `force`, and `force` skips the queue
    # check without ever showing the queue. Raise from it to refuse.
    #
    # @param session [Session] reloaded by the lock, so it reflects the row as
    #   the transition sees it
    # @param force [Boolean] the caller has read the queue and is discarding it
    # @param actor [String] how the archive line names whoever asked
    # @return [Boolean] true if it archived; false if, once the lock was held,
    #   the session could no longer be archived (a concurrent archive won)
    # @raise [Refused] when messages are queued and +force+ is false
    def guarded_archive!(session, force:, actor:)
      session.with_lock do
        next false unless session.may_archive?

        unless force
          queued = pending_messages(session)
          raise Refused, queued if queued.any?
        end

        yield if block_given?

        session.archive_actor = actor
        session.archive_forced = force
        session.archive!
        true
      end
    end

    # The messages an archive of +session+ would discard.
    #
    # @param session [Session]
    # @return [Array<EnqueuedMessage>] ordered, possibly empty
    def pending_messages(session)
      session.enqueued_messages.pending.ordered.to_a
    end

    # Whether archiving would discard anything.
    #
    # Deliberately not `pending_messages(session).any?`: content is validated up
    # to Session::PROMPT_MAX_LENGTH, and the bulk paths ask this per session
    # without ever reading a body.
    #
    # @param session [Session]
    # @return [Boolean]
    def blocked?(session)
      session.enqueued_messages.pending.exists?
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
    # @param batch [Boolean] whether the caller is archiving a batch, in which
    #   case `force` would apply to every session in it rather than this one.
    #   A caller that reads a per-session error and does what it says would
    #   otherwise discard queues it was never shown.
    # @return [String]
    def refusal_message(session, messages, batch: false)
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
        "told it would be delivered, and forcing throws it away." +
          (batch ? " On a batch archive that flag applies to every session in the batch, including ones whose " \
                   "queued messages you have not been shown." : "")
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
    private_class_method :message_count
  end
end
