# frozen_string_literal: true

module Sessions
  # Removes one message from a session's queue and closes the gap it leaves.
  #
  # The three delete doors take this path: the web delete
  # (`DELETE /sessions/:id/enqueued_messages/:mid`), the REST endpoint
  # (`DELETE /api/v1/sessions/:id/enqueued_messages/:mid`) and the `delete`
  # action of the `manage_enqueued_messages` MCP tool.
  #
  # It runs under the session's queue lock (Sessions::QueueTail.lock!), the one
  # every append and every EnqueuedMessage#reorder_to takes, and re-reads the
  # message's position under it. A position read outside the lock can belong to
  # a queue another writer is halfway through rewriting; decrementing from it
  # leaves a gap, fails the deferred `(session_id, position)` unique constraint
  # at COMMIT, or deadlocks on the rows both writers are shifting.
  #
  # A message deleted, delivered or reordered away from the caller's copy is
  # handled by the re-read: a row that is gone is left alone (shifting its old
  # neighbours would open a gap), and a moved row closes the gap where it really
  # is. The return value tells the caller which happened, so it logs the
  # position the row was really removed from, and no removal for a row that is
  # gone.
  #
  # The renumber is one bulk `position = position - 1`. It is correct under any
  # scan order because uniqueness on `(session_id, position)` is DEFERRABLE
  # INITIALLY DEFERRED and checked once at COMMIT against the final state
  # (#353).
  #
  # One variant, `withdraw_pending`, is for a writer taking back a message it
  # staged itself: Sessions::InterruptWithFollowUp, when the interrupt it was
  # staged for fails. It removes the row only while it is still `pending`. A
  # delivery claims the message (`processing`) under the session's row lock,
  # which the queue lock waits for, so a claim either commits first and the
  # withdrawal finds the row gone, or waits for the withdrawal. The row itself
  # is locked for the status read, because retiring a message as `undelivered`
  # (EnqueuedMessage#retire_as_stale!) writes the status without the session
  # lock; the read waits for that write and sees its result. It writes no Log
  # row: nobody asked for the message to be deleted, and the failure that
  # caused the withdrawal is reported by the caller.
  #
  # The other variant, `remove_delivered`, is for EnqueuedMessageProcessorService
  # removing the message it has just claimed (`processing`), inside the
  # transaction that holds the session's row lock (`FOR UPDATE`) and the claim's
  # row lock. Taking the queue lock and the row lock again waits on nothing,
  # since a transaction never waits on a lock it already holds. It removes the
  # row only while it is `processing`, and writes no Log row: the processor logs
  # the delivery itself ("Processing enqueued message at position N").
  #
  # With it, every path that removes a queued row goes through here. A row left
  # in place for good (archive, the stale sweep) is retired `undelivered`
  # instead, and a session's rows go with the session.
  #
  # Scope: the delete, the renumber and (for `call`) one Log row, committed
  # together. Renders nothing and checks nothing about the session's status.
  class RemoveQueuedMessage
    # @param message [EnqueuedMessage]
    # @return [Integer, nil] the position the message was removed from, read
    #   under the lock, or nil when the row no longer exists
    def self.call(message)
      remove(message) do |position|
        message.session.logs.create!(content: "Enqueued message at position #{position} removed", level: "info")
      end
    end

    # @param message [EnqueuedMessage]
    # @return [Integer, nil] the position the message was removed from, or nil
    #   when the row no longer exists or is no longer `pending`
    def self.withdraw_pending(message)
      remove(message, only_status: "pending")
    end

    # @param message [EnqueuedMessage] a message the processor has claimed
    #   (`processing`)
    # @return [Integer, nil] the position the message was removed from, or nil
    #   when the row no longer exists or is not `processing`
    def self.remove_delivered(message)
      remove(message, only_status: "processing")
    end

    # The transaction behind the three entry points. Yields the removed position
    # inside it, so a caller's Log row commits with the delete or not at all.
    def self.remove(message, only_status: nil)
      EnqueuedMessage.transaction do
        QueueTail.lock!(message.session_id)
        position, status = EnqueuedMessage.where(id: message.id).lock.pick(:position, :status)
        next nil if position.nil?
        next nil if only_status && status != only_status

        message.destroy!
        EnqueuedMessage.where(session_id: message.session_id)
                       .where("position > ?", position)
                       .update_all("position = position - 1")
        yield position if block_given?
        position
      end
    end
    private_class_method :remove
  end
end
