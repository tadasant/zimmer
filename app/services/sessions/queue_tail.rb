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
  # outside it orders nothing. Writers that compute their own `maximum + 1`
  # are not ordered by this lock; a collision with one of them still raises
  # `ActiveRecord::RecordNotUnique`.
  module QueueTail
    # @param session [Session]
    # @return [Integer] the position the next queued message should take
    def self.next_position!(session)
      Session.where(id: session.id).lock("FOR NO KEY UPDATE").pick(:id)
      (session.enqueued_messages.maximum(:position) || 0) + 1
    end
  end
end
