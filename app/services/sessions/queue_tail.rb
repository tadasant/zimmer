# frozen_string_literal: true

module Sessions
  # The next free position at the tail of a session's queue, read under a row
  # lock on the session.
  #
  # Two writers that both read `maximum(:position)` without a lock can read the
  # same N, and the second then dies on the deferred `(session_id, position)`
  # unique constraint at COMMIT. Taking `SELECT … FOR NO KEY UPDATE` on the
  # session row first makes every caller of this method wait its turn, so they
  # land at N+1 and N+2. It is taken without reloading the caller's instance.
  #
  # `NO KEY` because the lock only has to exclude other callers of this method:
  # it leaves alone the `KEY SHARE` lock that every insert of a child row (a log,
  # a transcript line) takes on the session through its foreign key.
  #
  # Callers must already be inside a transaction, and must insert the row in
  # that same transaction — the lock is released at COMMIT, and a position read
  # outside it orders nothing. Every writer that appends to a session's queue
  # reads its position here; `test/services/sessions/queue_tail_writers_test.rb`
  # fails on a `maximum(:position)` anywhere else in `app/`. Callers that already
  # hold `FOR UPDATE` on the session (`lock!`) lose nothing by calling it: a
  # transaction never waits on a lock it already holds.
  #
  # `EnqueuedMessage#reorder_to` and `Sessions::RemoveQueuedMessage` renumber
  # existing rows under the same lock (`QueueTail.lock!`), so a move, a request
  # to delete a queued message, and Sessions::InterruptWithFollowUp withdrawing
  # one it staged take turns with appends and with each other rather than
  # computing positions from rows another is rewriting.
  module QueueTail
    # @param session [Session]
    # @return [Integer] the position the next queued message should take
    def self.next_position!(session)
      lock!(session.id)
      (session.enqueued_messages.maximum(:position) || 0) + 1
    end

    # Take the queue lock on the session row and nothing else. For writers that
    # renumber rows already in the queue rather than append one. Same contract
    # as `next_position!`: call it inside the transaction that does the writes.
    #
    # @param session_id [Integer]
    # @return [void]
    def self.lock!(session_id)
      Session.where(id: session_id).lock("FOR NO KEY UPDATE").pick(:id)
    end
  end
end
