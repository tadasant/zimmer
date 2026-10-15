# frozen_string_literal: true

module Sessions
  # Flips a session's `push_notifications_enabled` opt-in.
  #
  # Every surface that toggles a session's push notifications routes through
  # here: the web UI's bell (`PATCH /sessions/:id/toggle_push_notifications`)
  # and the `toggle_push_notifications` MCP action. `SelfSessionActionSession`
  # deliberately leaves the action out of its whitelist, and the REST API has
  # no door for it.
  #
  # The flip reads the current value under a row lock (`SELECT … FOR UPDATE`)
  # and writes its negation in the same transaction. A plain
  # `update!(push_notifications_enabled: !push_notifications_enabled)` negates
  # whatever the caller's in-memory copy says, so two toggles that loaded the
  # same row cancel into one; under the lock the second waits for the first and
  # flips the value it committed. The write stays an `update!` rather than an
  # `update_all` so the model's validations and callbacks run.
  #
  # The caller's instance is reloaded under the lock, so any unsaved changes on
  # it are discarded, and it comes back carrying the committed value.
  #
  # Scope: one locked read and ONE `update!` on `push_notifications_enabled`.
  # It does not send, schedule or cancel any notification — the state machine
  # reads the flag when a transition happens. Not retry-safe in the idempotent
  # sense: a second call flips the flag back. A retry after a rolled-back
  # attempt is fine, because the rollback took the flip with it; a retry after
  # a COMMIT whose acknowledgement was lost flips the flag back.
  class TogglePushNotifications
    # @param session [Session]
    # @return [Session] the same instance, carrying the new `push_notifications_enabled`
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
        session.update!(push_notifications_enabled: !session.push_notifications_enabled)
      end
      session
    end
  end
end
