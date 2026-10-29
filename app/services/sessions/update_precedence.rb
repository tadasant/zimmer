# frozen_string_literal: true

module Sessions
  # Sets where ONE session sits in the spot queue, `precedence`, to a value the
  # caller has already chosen.
  #
  # Every surface that sets a session's rank on its own routes through here: the
  # web UI's rank editor and the Ranked view's inline edit
  # (`PATCH /sessions/:id/update_precedence`), the `change_precedence` MCP
  # action, and `PATCH /api/v1/sessions/:id` with `precedence` or `place` but no
  # `scheduling_class`. Two neighbouring writers are deliberately elsewhere:
  #
  # - A drag-and-drop landing is Sessions::ReorderPrecedence, which derives the
  #   value from two neighbours and may nudge them aside.
  # - A scheduling-class change that also places the session is
  #   Sessions::UpdateSchedulingClass, which writes the class and the rank in
  #   one UPDATE (REST's PATCH with both a `scheduling_class` and a rank).
  #
  # The value arrives resolved. A symbolic `place` is the surface's to turn into
  # a number (MCP and REST go through `Session#precedence_for_place`), and so is any
  # validation it does before the model sees the value — MCP refuses a
  # non-integer with its own message, while the web door lets the model's
  # numericality validation speak. A blank value is the model's "say nothing",
  # which writes SessionPrecedence::DEFAULT.
  #
  # The rules:
  # - The write and its log row land together in one transaction.
  # - A value equal to the stored one writes no log row. The comparison is
  #   against the stored value, not the in-memory one, so a retry after a failed
  #   write (the web door's with_db_retry) still logs the move.
  #
  # Scope: ONE save of `precedence` and at most one log row. It does not touch
  # the scheduling class, start or wake the session, or move any other row.
  #
  # Attributes the caller has already assigned on the session are saved by the
  # same save. A caller whose save is somebody else's write (REST's PATCH, where
  # Sessions::UpdateGoal may own it) passes a block: the rank is assigned, the
  # block does the save, and the log row follows it in the same transaction.
  class UpdatePrecedence
    # What the write did, for the surfaces that report the old value.
    Result = Data.define(:session, :previous, :precedence) do
      def changed?
        previous != precedence
      end
    end

    ACTOR_LABELS = { web: "", mcp: " via MCP", rest: " via the REST API" }.freeze

    # @param session [Session]
    # @param precedence [Integer, String, nil] the new rank, already resolved
    # @param actor [Symbol] :web, :mcp or :rest — named in the log row
    # @yield the save, when the caller owns it; the rank is assigned beforehand
    # @return [Result]
    # @raise [ActiveRecord::RecordInvalid] when the session refuses the value
    #   (out of range, not an integer) or fails another validation
    def self.call(session:, precedence:, actor: :web, &save)
      new(session: session, precedence: precedence, actor: actor).call(&save)
    end

    def initialize(session:, precedence:, actor:)
      @session = session
      @precedence = precedence
      @actor = actor
    end

    attr_reader :session, :precedence, :actor

    def call
      previous = nil
      session.transaction do
        previous = session.attribute_in_database("precedence")
        session.precedence = precedence
        block_given? ? yield : session.save!
        if previous != session.precedence
          session.logs.create!(
            content: "Precedence set#{ACTOR_LABELS.fetch(actor)} to #{session.precedence} (was #{previous})",
            level: "info"
          )
        end
      end

      Result.new(session: session, previous: previous, precedence: session.precedence)
    end
  end
end
