# frozen_string_literal: true

module Sessions
  # A cross-process "this session's status just changed" doorbell, for a web
  # request that is holding a tool call open until a session finishes a turn
  # (Sessions::SyncReply).
  #
  # The transition happens in the `worker` container and the request waits in
  # `web`, so an in-process notification cannot carry it. ActionCable can: the
  # production adapter is solid_cable, whose one listener thread per process
  # already polls the cable database every 0.1s for the browser's Turbo
  # streams. Subscribing here adds a channel to that existing poll — no new
  # database connection, no LISTEN, no thread per waiter.
  #
  # The payload is deliberately empty of meaning. A ring says "re-read the
  # session", nothing more, so a waiter never trusts a message over the row and
  # a dropped or duplicated ring costs latency, not correctness.
  #
  # No browser can subscribe to this stream: the only channel the app mounts is
  # Turbo::StreamsChannel, which accepts signed stream names only.
  module TurnSignal
    module_function

    def stream_name(session_id)
      "session_turn_signal:#{session_id}"
    end

    # Ring the doorbell. Called from Session#broadcast_status_change, so it
    # fires after commit on every status change saved through the model.
    # Swallowed: a waiter that misses a ring re-reads on its own backstop, and a
    # status change must never fail because nobody could be told about it.
    def publish(session)
      ActionCable.server.broadcast(stream_name(session.id), { status: session.status })
    rescue StandardError => e
      Rails.logger.warn("[Sessions::TurnSignal] Could not signal session #{session.id}: #{e.class}: #{e.message}")
    end

    # Subscribe `callback` to the doorbell for `session_id`. Returns the
    # unsubscribe proc; call it in an `ensure`.
    def subscribe(session_id, &callback)
      stream = stream_name(session_id)
      handler = ->(_message) { callback.call }
      ActionCable.server.pubsub.subscribe(stream, handler)
      -> { ActionCable.server.pubsub.unsubscribe(stream, handler) }
    end
  end
end
