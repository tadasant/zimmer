# frozen_string_literal: true

module Sessions
  # Flips a session's `favorited` star.
  #
  # Every surface that lets somebody star a session routes through here: the web
  # UI's star (`PATCH /sessions/:id/toggle_favorite`), `POST
  # /api/v1/sessions/:id/toggle_favorite`, and the `toggle_favorite` MCP action
  # (which `SelfSessionActionSession` inherits).
  #
  # The flip reads the current value under a row lock (`SELECT … FOR UPDATE`)
  # and writes its negation in the same transaction. A plain
  # `update!(favorited: !favorited)` negates whatever the caller's in-memory
  # copy says, so two toggles that loaded the same row cancel into one; under
  # the lock the second waits for the first and flips the value it committed.
  # The write stays an `update!` rather than an `update_all` so the model's
  # callbacks run: `Session#should_broadcast_to_index?` watches
  # `saved_change_to_favorited?` to refresh the star on every open board.
  #
  # The caller's instance is reloaded under the lock, so any unsaved changes on
  # it are discarded, and it comes back carrying the committed value.
  #
  # Scope: one locked read and ONE `update!` on `favorited`. Not retry-safe in
  # the idempotent sense: a second call flips the star back. A retry after a
  # rolled-back attempt is fine, because the rollback took the flip with it.
  class ToggleFavorite
    # @param session [Session]
    # @return [Session] the same instance, carrying the new `favorited`
    # @raise [ActiveRecord::RecordInvalid] when the session fails a validation
    def self.call(session:)
      new(session: session).call
    end

    def initialize(session:)
      @session = session
    end

    attr_reader :session

    def call
      session.transaction do
        session.reload(lock: true)
        session.update!(favorited: !session.favorited)
      end
      session
    end
  end
end
