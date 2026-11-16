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
  # Scope: the delete, the renumber and one Log row, committed together.
  # Renders nothing and checks nothing about the session's status.
  class RemoveQueuedMessage
    # @param message [EnqueuedMessage]
    # @return [Integer, nil] the position the message was removed from, read
    #   under the lock, or nil when the row no longer exists
    def self.call(message)
      EnqueuedMessage.transaction do
        QueueTail.lock!(message.session_id)
        position = EnqueuedMessage.where(id: message.id).pick(:position)
        next nil if position.nil?

        message.destroy!
        EnqueuedMessage.where(session_id: message.session_id)
                       .where("position > ?", position)
                       .update_all("position = position - 1")
        message.session.logs.create!(content: "Enqueued message at position #{position} removed", level: "info")
        position
      end
    end
  end
end
