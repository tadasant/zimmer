# frozen_string_literal: true

module Sessions
  # "Pause Until → Spot Queue": sleep a session now and leave it for the spot
  # scheduler, with no wake trigger and no wall-clock time attached.
  #
  # This is the sibling of Sessions::ScheduleWakeUp — the other half of the same
  # web-UI control — and the difference is the whole point. ScheduleWakeUp arms a
  # one-time trigger that fires at a time a human picked. This arms nothing: the
  # session goes dormant in `waiting` carrying the same metadata a ceiling pause
  # writes (SpotSessionPause), so the sweep that already resumes spot work picks
  # it up on the next pass where a Claude Code account is under both quota
  # targets and a session slot is free — in precedence order, behind whatever the
  # queue is already holding.
  #
  # == Why it reuses SpotSessionPause's record rather than inventing one
  #
  # A `waiting` session with nothing armed is the one shape Zimmer treats as
  # STRANDED: the refresh nudge continues it, and an interrupted job row recovers
  # it. SpotSessionPause's metadata is precisely the marker that says "dormant on
  # purpose, waiting on the gate" — every surface that reads it (the banner, the
  # bulk-refresh guard, get_session, the resume sweep) then explains and honors
  # this park for free. Inventing a parallel record would mean teaching each of
  # them a second thing that means the same.
  #
  # The reason is distinct (SpotSessionPause::QUEUED_REASON) because the two
  # stories are not the same: nothing interrupted this session, and no turn was
  # lost.
  #
  # == It pins the session to spot, and that is reversible
  #
  # A session that resolves to `priority` cannot sit in the spot queue: the sweep
  # resumes a non-spot sleeper on its very next pass, so the park would last
  # about five minutes. So the class is set to `spot` — but only when the session
  # does not already resolve there, since pinning one that derives `spot` from
  # its genesis would freeze it against a later policy change for no reason.
  #
  # Reversing it is the button the session page already carries: "Make this
  # session priority" promotes it and the next sweep resumes it, which is exactly
  # what a human who changed their mind wants. The panel says so before the
  # click.
  #
  # == Precedence is left alone
  #
  # Every session already carries a rank, and a session promoted to priority
  # keeps it for exactly this moment. Assigning one here would silently overwrite
  # a placement someone made on the Ranked view, and the Ranked view (`?view=
  # ranked`) is where the queue is ordered — this control decides that the
  # session waits, not where in the line it waits.
  class PauseIntoSpotQueue
    class Error < StandardError; end

    # What the session's banner and log say it is waiting on.
    DETAIL = "Parked in the spot queue from \"Pause Until\". No wake-up time is set: " \
             "it resumes when a Claude Code account is under both quota targets and a " \
             "session slot is free, in precedence order."

    Result = Data.define(:session, :pending_sleep, :pinned_to_spot)

    # @param session [Session] the session to park
    # @param prompt [String, nil] what the session should be resumed with; blank
    #   falls back to the recovery nudge SpotSessionPause sends
    # @return [Result]
    # @raise [Error] when the session's state makes the park a no-op
    def self.call(session:, prompt: nil)
      new(session: session, prompt: prompt).call
    end

    def initialize(session:, prompt: nil)
      @session = session
      @prompt = prompt.to_s.strip
    end

    attr_reader :session, :prompt

    def call
      unless ScheduleWakeUp::WAKEABLE_STATUSES.include?(session.status.to_s)
        raise Error, "Session #{session.id} is in \"#{session.status}\" state and cannot be put in the " \
                     "spot queue. Only sessions in #{ScheduleWakeUp::WAKEABLE_STATUSES.join(', ')} can be."
      end

      pinned = false

      # One transaction, for the same reason ScheduleWakeUp uses one: dropping
      # the old wake and parking the session are a single act, and a failure
      # after the drop would leave an awake session with nothing armed at all.
      Session.transaction do
        # "Not at that time, THIS instead" — the same gesture as picking a second
        # time in the panel, so it supersedes an earlier Pause Until the same way.
        SupersedePendingWakes.call(session: session)

        pinned = pin_to_spot!
        park!
      end

      session.reload
      session.logs.create!(level: "info", content: log_line(pinned))

      Result.new(session: session, pending_sleep: session.metadata&.dig("pending_sleep") == true,
                 pinned_to_spot: pinned)
    end

    private

    # @return [Boolean] whether the class had to be changed
    def pin_to_spot!
      return false if session.spot?

      session.update!(scheduling_class: SessionGenesis::SPOT)
      true
    end

    # The park itself. `needs_input` sleeps immediately; a `running` session does
    # not sleep mid-turn — `pending_sleep` is what the pause callback reads to
    # carry it needs_input → waiting once the turn ends, which is the same
    # deferral a time-based Pause Until gets. A `waiting` session is already
    # dormant and only needs the record.
    def park!
      metadata = (session.metadata || {}).merge(
        SpotSessionPause::PAUSED_AT => Time.current.utc.iso8601,
        SpotSessionPause::PAUSED_REASON => SpotSessionPause::QUEUED_REASON,
        SpotSessionPause::PAUSED_DETAIL => DETAIL,
        SpotSessionPause::PAUSED_COUNT => (session.metadata || {})[SpotSessionPause::PAUSED_COUNT].to_i + 1,
        "paused_by" => SpotSessionPause::PAUSED_BY
      )
      metadata[SpotSessionPause::QUEUED_PROMPT] = prompt if prompt.present?
      metadata["pending_sleep"] = true if session.running?

      session.update!(metadata: metadata)
      session.sleep! if session.needs_input? && session.may_sleep?
    end

    def log_line(pinned)
      [
        "[Pause Until] Parked in the spot queue — no wake-up time is set.",
        pinned ? "This session is now spot (it was priority); make it priority again to resume it on the next sweep." : nil,
        "Queue position: precedence #{session.precedence}."
      ].compact.join(" ")
    end
  end
end
