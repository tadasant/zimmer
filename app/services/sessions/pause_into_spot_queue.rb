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
      # Session#pausable_until? rather than the service's own WAKEABLE_STATUSES,
      # and deliberately: a `waiting` session that has never started is queued
      # for SPAWN, not asleep, and parking one writes a queue record over a
      # session the spawn pipeline still owns — the sweep would then "resume" a
      # session that has no runtime session to resume. The web UI checks the same
      # predicate before it gets here; keeping it in the service is what stops
      # the MCP surface from being the one path that skips it.
      unless session.pausable_until?
        raise Error, "Session #{session.id} is in \"#{session.status}\" state and cannot be put in the " \
                     "spot queue. Only a session that has started and is in " \
                     "#{ScheduleWakeUp::WAKEABLE_STATUSES.join(', ')} can be."
      end

      pinned = false

      # One transaction, for the same reason ScheduleWakeUp uses one: dropping
      # the old wake and parking the session are a single act, and a failure
      # after the drop would leave an awake session with nothing armed at all.
      Session.transaction do
        # "Not at that time, THIS instead" — the same gesture as picking a second
        # time in the panel, so it supersedes an earlier Pause Until the same way.
        SupersedePendingWakes.call(session: session, note: "Pause Until → Spot Queue")

        pinned = pin_to_spot!
        park!
        session.logs.create!(level: "info", content: log_line(pinned))
      end

      session.reload

      Result.new(session: session, pending_sleep: session.metadata&.dig("pending_sleep") == true,
                 pinned_to_spot: pinned)
    rescue ActiveRecord::RecordInvalid => e
      # Chiefly the catalog coupling: a session whose agent root or skills no
      # longer resolve fails its own validations, and a park that raised
      # RecordInvalid would surface as a 500 in the panel and a raw exception in
      # the MCP tool. Nothing was committed — the transaction saw to that.
      raise Error, "Could not park session #{session.id} in the spot queue: " \
                   "#{e.record.errors.full_messages.join(', ')}. No changes were made."
    end

    private

    # @return [Boolean] whether the class had to be changed
    def pin_to_spot!
      return false if session.spot?

      session.update!(scheduling_class: SessionGenesis::SPOT)
      true
    end

    # The park itself. `needs_input` sleeps immediately; a `running` session gets
    # `pending_sleep`, which the pause callback reads to carry it needs_input →
    # waiting once the turn ends. A `waiting` session is already dormant and only
    # needs the record.
    #
    # Whether that turn is allowed to end is the CALLER's choice, not this
    # service's: the web UI's "Pause Until" stops it immediately
    # (Sessions::HaltRunningTurn, invoked after this returns), while the MCP tool
    # defers by default because its commonest caller is a session parking itself.
    # Either way the deferral written here is what the session falls back on.
    #
    # `merge_metadata!` rather than a whole-column write: the session may be
    # RUNNING, and AgentSessionJob is writing its own keys to the same column
    # from another process. A read-modify-write of the hash this request happens
    # to be holding would drop whatever the job wrote in between. It also skips
    # validations, which is what keeps a park working on a session whose catalog
    # has since gone stale.
    def park!
      updates = {
        SpotSessionPause::PAUSED_AT => Time.current.utc.iso8601,
        SpotSessionPause::PAUSED_REASON => SpotSessionPause::QUEUED_REASON,
        SpotSessionPause::PAUSED_DETAIL => DETAIL,
        "paused_by" => SpotSessionPause::PAUSED_BY
      }
      updates[SpotSessionPause::QUEUED_PROMPT] = prompt if prompt.present?
      updates["pending_sleep"] = true if session.running?

      # PENDING_SLEEP_REQUIRES_WAKE goes, and it is not housekeeping: it means
      # "sleep only if something is still armed to wake you", and this park has
      # just destroyed every armed wake and creates none. Left in place, a
      # session carrying it from a system-recovery resume would reach its turn
      # end, find nothing armed, DROP the sleep, and come to rest in needs_input
      # holding a queue record no sweep can act on. A deliberate sleep is
      # unconditional — see SessionStateMachine#execute_pending_sleep.
      #
      # A stale QUEUED_PROMPT goes too when the box was left empty, or a park
      # made after an earlier one would silently resume on the earlier text.
      removals = [ SessionStateMachine::PENDING_SLEEP_REQUIRES_WAKE ]
      removals << SpotSessionPause::QUEUED_PROMPT if prompt.blank?

      session.merge_metadata!(updates, removals)
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
