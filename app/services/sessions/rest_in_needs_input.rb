# frozen_string_literal: true

module Sessions
  # A session declaring that the turn it is in ends with a human, not with a
  # sleep: it comes to rest in `needs_input`, on the homepage action queue,
  # whatever wakes it has armed.
  #
  # == Why this exists
  #
  # A follow-up does not cancel a session's own wakes (#898), and once it has
  # answered, the session goes back to sleep on them (#1212). That is right for a
  # router asked a question mid-wait-loop, and it is wrong for the other answer —
  # "I need a decision from you" — because the session then sits in `waiting`,
  # off the action queue, until its backstop fires. A session that arms a wake in
  # the same turn it asks the human something lands in the same place.
  #
  # Session 20141 armed a 07:30Z backstop, wanted to hand back to the operator at
  # 05:46Z, and had nothing on the self-session server to drop it with, so it
  # armed a two-minute dummy wake whose firing would destroy the real one.
  # Session 19775 asked the operator to approve a cutover while asleep on a
  # watcher and a 20:00Z backstop, and was hidden for hours. Both wanted to be
  # seen; neither had a way to say so.
  #
  # == Two ways to rest there
  #
  # By default the wakes STAY armed. The wake-backed sleep intent for this turn
  # is dropped, so `pause` leaves the session in `needs_input`, and whichever
  # comes first — the human's reply or one of the wakes — resumes it:
  # Trigger#follow_up_session! delivers to a `needs_input` session just as well.
  # That is the shape 19775 needed: "I need you, and wake me if the child
  # finishes first." It is also the shape a session watching only
  # `ao_event` watchers has always rested in (#648), so it is not a new state.
  #
  # With `cancel_wakes`, every unfired one-time wake aimed at this session is
  # destroyed too — `wake_me_up_later` schedules AND
  # `wake_me_up_when_session_changes_state` watchers — for a session whose wait
  # no longer has a reason. Only triggers made of nothing but one-shot wakes are
  # touched (Trigger#one_time_reuse_trigger?), since a trigger that also carries a
  # recurring schedule or a Slack condition does other work, and only `enabled`
  # ones: a `failed` trigger is the record of a wake that could not fire, and it
  # is the user's to clear.
  #
  # == What it does not override
  #
  # Only a wake-backed intent (Session::PENDING_SLEEP_REASONS_REQUIRING_WAKE) is
  # dropped. An unconditional one — a spot-queue park, a deliberate sleep, a
  # platform dormancy — is somebody's decision that this session should not run,
  # and it stands; the result says so.
  #
  # == It lasts until the session waits again
  #
  # Dropping this turn's intent is not enough on its own: the next thing to
  # resume the session — a deploy interrupting the turn before its pause, a
  # router's follow-up, a Slack message — would write a fresh wake-backed
  # re-sleep and bury the question again. So the hand-back is also stamped
  # (SessionStateMachine::HANDED_BACK_TO_HUMAN), and both re-sleep branches skip
  # a session carrying it. Arming a new wake clears the stamp, because that is
  # the session deciding to wait again — which is also why a wake armed AFTER
  # this call in the same turn puts the session back to sleep. Call it last.
  #
  # Refused on a session already asleep: a `waiting` session is not in a turn, so
  # there is nothing to come to rest, and a self-session caller is never there.
  class RestInNeedsInput
    class Error < StandardError; end

    RESTABLE_STATUSES = %w[running needs_input].freeze

    Result = Struct.new(
      :cancelled_trigger_ids, :dropped_sleep_reason, :unconditional_sleep_reason, :wakes_still_armed,
      keyword_init: true
    )

    def self.call(session:, cancel_wakes: false)
      new(session: session, cancel_wakes: cancel_wakes).call
    end

    def initialize(session:, cancel_wakes:)
      @session = session
      @cancel_wakes = cancel_wakes
    end

    attr_reader :session

    def call
      raise Error, refusal_message unless RESTABLE_STATUSES.include?(session.status)

      cancelled = []
      dropped = nil

      Session.transaction do
        if @cancel_wakes
          cancelled = cancellable_triggers.map do |trigger|
            trigger.destroy!
            trigger.id
          end
        end

        session.reload
        if session.metadata&.dig("pending_sleep") == true && session.pending_sleep_requires_wake?
          dropped = session.metadata[Sessions::StopRecord::PENDING_SLEEP_REASON].presence || "wake-backed"
          session.remove_metadata!(SessionStateMachine::PENDING_SLEEP_KEYS)
        end
        session.merge_metadata!(SessionStateMachine::HANDED_BACK_TO_HUMAN => Time.current.utc.iso8601)

        session.logs.create!(content: log_line(cancelled, dropped), level: "info")
      end

      session.reload
      Result.new(
        cancelled_trigger_ids: cancelled,
        dropped_sleep_reason: dropped,
        unconditional_sleep_reason: unconditional_sleep_reason,
        wakes_still_armed: wakes_still_armed?
      )
    end

    private

    # preload, not includes, for the reason SupersedePendingWakes gives: an
    # eager-loading join filtered on condition columns would truncate the
    # association and make a mixed trigger look like a pure wake.
    def cancellable_triggers
      # Row-locked so a scheduler fire racing this call either lands first (and
      # its prompt is queued as the next turn, which the result warns about) or
      # finds the row gone.
      Trigger
        .where(reuse_session: true, last_session_id: session.id, status: "enabled")
        .lock
        .preload(:trigger_conditions)
        .select do |trigger|
          trigger.one_time_reuse_trigger? &&
            trigger.trigger_conditions.any? { |condition| condition.last_triggered_at.nil? }
        end
    end

    # Armed and still able to fire after this turn. A group a wake fired into
    # this turn is held (`wake_held_at`) and retired at this turn's pause, so it
    # does not count.
    def wakes_still_armed?
      TriggerCondition
        .joins(:trigger)
        .includes(:trigger)
        .where(condition_type: %w[schedule ao_event], last_triggered_at: nil)
        .where(triggers: { last_session_id: session.id, reuse_session: true, status: "enabled", wake_held_at: nil })
        .to_a
        .then do |conditions|
          watched = Session.watched_session_states(conditions)
          conditions.any? do |condition|
            (condition.one_time_schedule? || condition.session_scoped_ao_event?) &&
              Session.one_time_wake_pending?(condition, watched_states: watched)
          end
        end
    end

    def unconditional_sleep_reason
      return unless session.metadata&.dig("pending_sleep") == true

      session.metadata[Sessions::StopRecord::PENDING_SLEEP_REASON].presence || "unstamped"
    end

    def log_line(cancelled, dropped)
      parts = [ "Handing back to a human: this turn comes to rest in needs_input" ]
      parts << "dropped the #{dropped} re-sleep" if dropped
      parts << "cancelled wake trigger(s) #{cancelled.join(', ')}" if cancelled.any?
      parts.join(" — ")
    end

    def refusal_message
      if session.waiting?
        "Session #{session.id} is waiting, not in a turn, so there is no turn to come to rest. Call this " \
          "from inside the turn that hands back, before it ends. To take over a sleeping session, follow it " \
          "up or restart it."
      else
        "Session #{session.id} is #{session.status}; only a running or needs_input session can come to rest in needs_input."
      end
    end
  end
end
