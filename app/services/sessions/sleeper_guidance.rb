# frozen_string_literal: true

module Sessions
  # What to tell a caller about a session asleep on a wake-up it armed itself.
  #
  # "Asleep until 22:58Z" is true about the SCHEDULERS — no queue worker, spot
  # gate or `start_now` / `restart` starts the session early — and false about a
  # message: a `follow_up` takes a turn immediately and the session goes back
  # to the same wait afterwards (SessionStateMachine#preserve_pending_wakes_across_follow_up).
  # Every surface that says "paused" used to say only the first half, and a Live
  # Mode assistant read it as "my message was not delivered", tried `start_now`,
  # `restart` and `force_start` in turn, and told a driver the answer would come
  # at the wake time when it had already been given a minute earlier.
  #
  # So every sentence that tells a caller a sleeper will not start early also
  # says, in the same words everywhere, that a follow-up still reaches it — and,
  # when the last thing the session did was answer one, that the answer exists
  # and where to read it.
  module SleeperGuidance
    FOLLOW_UP_STILL_WAKES =
      "A message still reaches it now: `follow_up` wakes it for one turn immediately, " \
      "and it goes back to this wait after answering."

    # When the session's last turn answered a follow-up and went back to sleep,
    # the sentence that says so and names the read that returns the answer; nil
    # otherwise. Keyed off the stop record rather than the queue, because an
    # empty queue is also what an undelivered-and-lost message would look like —
    # `follow_up_resleep` is only ever written after the turn that took one ended.
    def self.last_follow_up_answered(session)
      metadata = session.metadata || {}
      return nil unless session.waiting? && metadata[StopRecord::REASON] == StopRecord::FOLLOW_UP_RESLEEP

      at = metadata[StopRecord::AT].presence
      "Its last follow-up has already been delivered and answered: it went back to sleep" \
        "#{" at #{at}" if at} after replying. Read the reply with `get_session` and " \
        "`transcript_last_messages: 2`."
    end

    # The tail to append to a refusal of a start path (`start_now`, `restart`,
    # `force_start`) on this session. Empty when the session is not a sleeper
    # and has not just answered a follow-up — the refusal then stands alone.
    def self.refusal_tail(session, paused: session_paused?(session))
      parts = []
      parts << "To deliver something to it, do not start it — send a `follow_up`. #{FOLLOW_UP_STILL_WAKES}" if paused
      parts << last_follow_up_answered(session)
      parts.compact.join(" ")
    end

    # Rescued to false: this only decides whether a refusal grows a hint, and a
    # hint is never worth failing the refusal over.
    def self.session_paused?(session)
      session.waiting? && session.paused_until_scheduled_time?
    rescue ActiveRecord::ActiveRecordError
      false
    end
  end
end
