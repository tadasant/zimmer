# frozen_string_literal: true

module Sessions
  # Moves ONE session between spot and priority, optionally placing it in the
  # spot queue in the same write, and starts it when the move promoted a waiting
  # session.
  #
  # Every surface that changes a session's scheduling class routes through here:
  # the web UI's Promote / Demote buttons and the session page's class form
  # (`PATCH /sessions/:id/update_scheduling_class`), the `change_scheduling_class`
  # MCP action, and `PATCH /api/v1/sessions/:id` with `scheduling_class`.
  #
  # == The class
  #
  # "spot" or "priority" is written on the row. A blank one (nil or "") clears
  # it, and the session goes back to deriving its class from its origin. Anything
  # else raises UnknownSchedulingClass before anything is written. Trimming
  # whitespace is the surface's business: the web form strips, MCP and REST do not.
  #
  # == The rank, if the caller named one
  #
  # Either `precedence:` (an absolute value, which the model's validations
  # check) or `place:` (a symbolic one, SessionPrecedence::PLACES), never both.
  # A place resolves through `Session#precedence_for_place`, the same method
  # MCP's `change_precedence` and REST's PATCH use: the session is excluded from
  # the population it is measured against, and the result is floored at the
  # rank it already holds. So a session already at the head of the spot queue
  # keeps its number rather than being walked down to a few points above a
  # runner-up far below it. Naming neither leaves the rank alone.
  #
  # The class and the rank go in ONE `update!`, so `saved_change_to_scheduling_class?`
  # (which the Ranked view's membership broadcast keys on) sees both, and the
  # write and its log rows commit together. The "was" values are read from the
  # stored row, so a retry after a failed write still logs the move.
  #
  # == The start
  #
  # Promoting a waiting session starts it through Sessions::StartNow. The hold it
  # releases carries a deferred re-check up to an hour out, and "make this one
  # session priority" is not a request to wait that long. Only on the transition
  # INTO priority, and only for a waiting session: re-saving a priority session
  # must not restart it, and a demotion starts nothing. A stranded session
  # (StartNow's `nothing_queued`) is left alone, and the result says so.
  #
  # The start runs after the write commits. A caller composing this write into
  # a larger transaction or a retry block (REST's PATCH, the web door's
  # with_db_retry) passes `start: false` and calls #start_if_promoted once the
  # write is settled, so a retry never re-runs a start and a start never runs
  # inside a transaction it does not own.
  #
  # Attributes the caller has already assigned on the session are saved by the
  # same `update!`. REST's PATCH relies on that to keep a class change and its
  # other columns in one save, because `after_commit` callbacks read only the
  # last save's changes.
  class UpdateSchedulingClass
    class Error < StandardError; end

    # A class that is neither "spot", "priority" nor blank. The doors word their
    # own refusal; the value is on #scheduling_class.
    class UnknownSchedulingClass < Error
      attr_reader :scheduling_class

      def initialize(scheduling_class)
        @scheduling_class = scheduling_class
        super("Unknown scheduling class: #{scheduling_class}")
      end
    end

    NOT_GIVEN = Object.new.freeze
    private_constant :NOT_GIVEN

    # Named in the log rows and in StartNow's "Started now by …" line.
    ACTOR_LABELS = { web: "", mcp: " via MCP", rest: " via the REST API" }.freeze
    START_ACTORS = {
      web: "a user promoting it in the web UI",
      mcp: "an agent promoting it through MCP",
      rest: "the REST API promoting it"
    }.freeze

    # What the write did, for the surfaces that report the old values.
    Result = Data.define(:session, :previous_class, :previous_precedence, :start, :actor) do
      def precedence_changed?
        previous_precedence != session.precedence
      end

      # The move went INTO priority on a session that is waiting for a turn.
      def promoted_waiting?
        previous_class != SessionGenesis::PRIORITY &&
          session.priority_class == SessionGenesis::PRIORITY && session.waiting?
      end
    end

    # @param session [Session]
    # @param scheduling_class [String, nil] "spot", "priority", or blank to derive
    # @param actor [Symbol] :web, :mcp or :rest — named in the log rows
    # @param precedence [Integer, String, nil] an absolute rank; omit to keep it
    # @param place [String, nil] a symbolic rank (SessionPrecedence::PLACES)
    # @param start [Boolean] false to leave the promotion start to #start_if_promoted
    # @return [Result]
    # @raise [UnknownSchedulingClass] on a class that is not one of SessionGenesis::CLASSES
    # @raise [ArgumentError] on both `precedence:` and `place:`, or an unknown place
    # @raise [ActiveRecord::RecordInvalid] when the session refuses the rank
    def self.call(session:, scheduling_class:, actor:, precedence: NOT_GIVEN, place: nil, start: true)
      new(session: session, scheduling_class: scheduling_class, actor: actor,
        precedence: precedence, place: place).call(start: start)
    end

    # Start the session a deferred write promoted, if it did. Returns the
    # Sessions::StartNow result, or nil when the write was not a promotion of a
    # waiting session.
    #
    # @param result [Result]
    def self.start_if_promoted(result)
      return nil unless result.promoted_waiting?

      Sessions::StartNow.call(result.session, actor: START_ACTORS.fetch(result.actor))
    end

    def initialize(session:, scheduling_class:, actor:, precedence:, place:)
      @session = session
      @scheduling_class = scheduling_class.presence
      @actor = actor
      @precedence = precedence
      @place = place.presence
    end

    attr_reader :session, :scheduling_class, :actor, :precedence, :place

    def call(start:)
      if scheduling_class && !SessionGenesis::CLASSES.include?(scheduling_class.to_s)
        raise UnknownSchedulingClass, scheduling_class
      end
      raise ArgumentError, SessionPrecedence::BOTH_PLACE_AND_PRECEDENCE if place && precedence != NOT_GIVEN

      previous_class = nil
      previous_precedence = nil
      session.transaction do
        previous_class = stored_class
        previous_precedence = session.attribute_in_database("precedence")

        attrs = { scheduling_class: scheduling_class&.to_s }
        if place
          attrs[:precedence] = session.precedence_for_place(place.to_s)
        elsif precedence != NOT_GIVEN
          attrs[:precedence] = precedence
        end
        session.update!(attrs)

        log_changes(previous_class, previous_precedence)
      end

      result = Result.new(session: session, previous_class: previous_class,
        previous_precedence: previous_precedence, start: nil, actor: actor)
      return result unless start

      result.with(start: self.class.start_if_promoted(result))
    end

    private

    # The class the stored row resolves to, rather than the in-memory one, so a
    # retry after a failed write (the web door's with_db_retry) still logs the move.
    def stored_class
      session.attribute_in_database("scheduling_class").presence ||
        SessionGenesis.effective_class(session.genesis_key)
    end

    def log_changes(previous_class, previous_precedence)
      label = ACTOR_LABELS.fetch(actor)
      if previous_class != session.priority_class
        session.logs.create!(
          content: "Scheduling class set#{label} to #{session.priority_class} (was #{previous_class})",
          level: "info"
        )
      end
      if previous_precedence != session.precedence
        session.logs.create!(
          content: "Precedence set#{label} to #{session.precedence} (was #{previous_precedence})",
          level: "info"
        )
      end
    end
  end
end
