# frozen_string_literal: true

module Sessions
  # Why a session went dormant, written at the moment it went dormant.
  #
  # == The gap this closes (#608)
  #
  # Every mechanism that stops a running session is supposed to leave a legible
  # record: an auth-outage park writes `auth_outage_reason` + `auth_outage_parked_at`,
  # a spot ceiling pause writes `spot_pause_reason`, a failed MCP handshake writes
  # `failure_reason`. On 2026-08-22 three PRIORITY sessions each started cleanly —
  # fresh `job_started_at`, new pid, every MCP server `connected` — and were back in
  # `waiting` sixty to seventy-five seconds later carrying none of those keys and no
  # `exit_status`. Nothing on the row said what had stopped them.
  #
  # A stop that writes nothing is not merely unlogged. A wake cannot be verified
  # from the wake side, a scheduler cannot account for a start budget that silently
  # un-did itself, and the row sits in `waiting` looking exactly like one that was
  # never woken at all.
  #
  # So this is written on EVERY sleep, not only the ones a mechanism claims. When
  # no mechanism claims it the reason is #UNATTRIBUTED, which is a finding rather
  # than a blank: it says the transition happened, when it happened, and that Zimmer
  # could not name a cause — and it says so on the session's own timeline, in its
  # metadata and in `get_session`, so the next occurrence is diagnosable from the
  # record instead of from a re-poll a minute later.
  #
  # == Two halves, and why both
  #
  # **Provenance at the intent.** A running session does not sleep directly; it is
  # marked `pending_sleep` and the pause callback carries it needs_input -> waiting.
  # The mark and the mechanism's own record are two writes, so a failure between
  # them leaves the intent with nothing explaining it. #pending_sleep stamps the
  # cause into the SAME write as the intent, so the provenance cannot be lost
  # separately from the thing it explains.
  #
  # **Classification at the transition.** #classify reads whatever the row actually
  # carries when the sleep lands — the provenance first, then the park mechanisms
  # SessionWaitingReason ranks, then the markers the other dormancies write. It
  # never guesses: an unrecognised shape is named as such.
  class StopRecord
    # Written by #record! on every sleep, and on the one direct `running -> waiting`
    # write that does not go through the state machine (SpotSessionHold).
    REASON = "stopped_reason"
    DETAIL = "stopped_detail"
    AT = "stopped_at"

    # Stamped alongside `pending_sleep`, by the same write, so a deferred sleep
    # carries the name of whatever asked for it.
    PENDING_SLEEP_REASON = "pending_sleep_reason"

    # The record itself. Cleared when the session starts running again, and listed
    # in Session::STALE_RETRY_METADATA_KEYS so a restart-from-scratch drops it too.
    #
    # PENDING_SLEEP_REASON is deliberately NOT one of them: it is the provenance of
    # the `pending_sleep` FLAG, and the two have to be cleared together or a restart
    # would strip the reason and leave the intent behind, unexplained — which is the
    # shape of the defect this whole class exists for. SessionStateMachine clears
    # the pair, in #clear_pending_sleep and in #execute_pending_sleep.
    STOP_KEYS = [ REASON, DETAIL, AT ].freeze

    METADATA_KEYS = (STOP_KEYS + [ PENDING_SLEEP_REASON ]).freeze

    # The closed set of causes. `unattributed` is a real member: it is what the
    # record says when nothing on the row explains the stop.
    AUTH_OUTAGE_PARK = "auth_outage_park"
    SPOT_HOLD = "spot_hold"
    SPOT_PAUSE = "spot_pause"
    SCHEDULED_WAKE = "scheduled_wake"
    DELIBERATE_SLEEP = "deliberate_sleep"
    SYSTEM_RECOVERY_RESLEEP = "system_recovery_resleep"
    HALTED_TURN = "halted_turn"
    UNSTARTED_REQUEUE = "unstarted_requeue"
    USER_PAUSE = "user_pause"
    UNATTRIBUTED = "unattributed"

    class << self
      # The `pending_sleep` pair, for callers that mark a RUNNING session to sleep
      # at the end of its turn. Always merged in one statement with whatever else
      # the caller is recording, so the intent and its cause land together.
      #
      # @param reason [String] one of the causes above
      # @return [Hash]
      def pending_sleep(reason)
        { "pending_sleep" => true, PENDING_SLEEP_REASON => reason }
      end

      # Record why this session is now dormant.
      #
      # Never raises: a session that stopped has stopped, and losing the record of
      # it must not also lose the transition that produced it. A failure here is
      # logged and swallowed, which is the same bargain every other bookkeeping
      # side effect on the sleep path makes.
      #
      # @param session [Session]
      # @param reason [String, nil] the cause when the caller knows it; classified
      #   from the row when nil
      # @param detail [String, nil] a sentence for a human; derived when nil
      # @return [String, nil] the reason recorded
      def record!(session, reason: nil, detail: nil)
        return nil if session.nil?

        reason ||= classify(session)
        detail ||= detail_for(session, reason)

        session.merge_metadata!(
          {
            REASON => reason,
            DETAIL => detail,
            AT => Time.current.utc.iso8601
          }
        )

        announce_unattributed(session, detail) if reason == UNATTRIBUTED

        reason
      rescue StandardError => e
        Rails.logger.error(
          "[Sessions::StopRecord] Could not record why session #{session&.id} stopped: " \
          "#{e.class}: #{e.message}"
        )
        nil
      end

      # What the row says stopped this session.
      #
      # Order matters, and it is "who acted" before "what is on the row":
      #
      # 1. The provenance stamped with the sleep intent. It names the actor that
      #    caused THIS stop, and it is the only source that survives when the
      #    mechanism's own follow-up write did not land.
      # 2. The three park mechanisms, ranked by SessionWaitingReason so this cannot
      #    disagree with what `get_session` and the session page render.
      # 3. The remaining dormancy markers, each of which is written by exactly one
      #    path.
      # 4. An armed one-time wake — the ordinary "the agent asked to be woken later"
      #    sleep, which writes no marker of its own because the trigger IS its record.
      #
      # @return [String] one of the causes above; UNATTRIBUTED when none of them fits
      def classify(session)
        metadata = session.metadata || {}

        stamped = metadata[PENDING_SLEEP_REASON].presence
        return stamped if stamped

        mechanism = SessionWaitingReason.for(session)&.current
        case mechanism&.key
        when SessionWaitingReason::AUTH_OUTAGE_PARK then return AUTH_OUTAGE_PARK
        when SessionWaitingReason::SPOT_PAUSE then return SPOT_PAUSE
        when SessionWaitingReason::SPOT_HOLD then return SPOT_HOLD
        end

        return DELIBERATE_SLEEP if metadata[Session::DELIBERATE_SLEEP_KEY].present?
        return UNSTARTED_REQUEUE if metadata[Sessions::ReturnToQueue::REASON_KEY].present?
        return USER_PAUSE if metadata["paused_by"].present?
        return SCHEDULED_WAKE if armed_wake?(session)

        UNATTRIBUTED
      rescue StandardError => e
        Rails.logger.error(
          "[Sessions::StopRecord] Could not classify the stop of session #{session&.id}: " \
          "#{e.class}: #{e.message}"
        )
        UNATTRIBUTED
      end

      private

      # Read through the session's own predicate so this agrees with every start
      # path about what "asleep on a wake" means. Fails to FALSE: an unreadable
      # trigger table must not let an unexplained stop borrow an explanation.
      def armed_wake?(session)
        session.awaiting_scheduled_wake?
      rescue StandardError
        false
      end

      def detail_for(session, reason)
        metadata = session.metadata || {}

        case reason
        when AUTH_OUTAGE_PARK
          "Parked because the runtime's login pool had nothing usable " \
          "(#{metadata['auth_outage_reason'].presence || 'reason not recorded'})."
        when SPOT_PAUSE
          "Paused into the spot queue (#{metadata[SpotSessionPause::PAUSED_REASON].presence || 'reason not recorded'})."
        when SPOT_HOLD
          "Held at the spot gate before its turn began."
        when SCHEDULED_WAKE
          "Slept on a wake-up it has armed."
        when DELIBERATE_SLEEP
          "Slept on purpose by a human or an API caller, with nothing armed to wake it."
        when SYSTEM_RECOVERY_RESLEEP
          "Returned to the sleep it was recovered out of; its wake-ups are still armed."
        when HALTED_TURN
          "Its running turn was halted deliberately."
        when UNSTARTED_REQUEUE
          "Returned to the queue without ever running " \
          "(#{metadata[Sessions::ReturnToQueue::REASON_KEY].presence || 'reason not recorded'})."
        when USER_PAUSE
          "Paused by #{metadata['paused_by']}."
        when UNATTRIBUTED
          "Went dormant with nothing on the record naming a cause: no park, no pause, no armed " \
          "wake-up and no exit status. Nothing is scheduled to wake it, so it stays in `waiting` " \
          "until a start path picks it up. See tadasant/zimmer#608."
        else
          "Went dormant: #{reason}."
        end
      end

      # The operator signal the silent stop had none of. Deliberately the session's
      # OWN timeline rather than an alert: it is read by every surface that renders
      # the session, it survives the process that wrote it, and it does not page a
      # human for a session that is dormant rather than broken.
      def announce_unattributed(session, detail)
        Rails.logger.warn(
          "[Sessions::StopRecord] Session #{session.id} went dormant with no attributable cause " \
          "(status=#{session.status}, exit_status=#{(session.metadata || {})['exit_status'].inspect})"
        )
        session.logs.create!(level: "warning", content: detail)
      rescue StandardError => e
        Rails.logger.error(
          "[Sessions::StopRecord] Could not announce the unattributed stop of session " \
          "#{session.id}: #{e.class}: #{e.message}"
        )
      end
    end
  end
end
