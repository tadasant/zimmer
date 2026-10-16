# frozen_string_literal: true

module Sessions
  # Sets where ONE session sits in the spot queue, `precedence`, to a value the
  # caller has already chosen.
  #
  # Every surface that sets a session's rank on its own routes through here: the
  # web UI's rank editor and the Ranked view's inline edit
  # (`PATCH /sessions/:id/update_precedence`) and the `change_precedence` MCP
  # action. Three neighbouring writers are deliberately elsewhere:
  #
  # - A drag-and-drop landing is Sessions::ReorderPrecedence, which derives the
  #   value from two neighbours and may nudge them aside.
  # - A scheduling-class change that also places the session (the web
  #   `update_scheduling_class`, MCP `change_scheduling_class`) writes the class
  #   and the rank in one UPDATE, inline in each door.
  # - `PATCH /api/v1/sessions/:id` takes `precedence` as one column of a general
  #   update and logs nothing.
  #
  # The value arrives resolved. A symbolic `place` is the surface's to turn into
  # a number (MCP goes through `Session#precedence_for_place`), and so is any
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
  # Scope: ONE `update!` on `precedence` and at most one log row. It does not
  # touch the scheduling class, start or wake the session, or move any other row.
  class UpdatePrecedence
    # What the write did, for the surfaces that report the old value.
    Result = Data.define(:session, :previous, :precedence) do
      def changed?
        previous != precedence
      end
    end

    ACTOR_LABELS = { web: "", mcp: " via MCP" }.freeze

    # @param session [Session]
    # @param precedence [Integer, String, nil] the new rank, already resolved
    # @param actor [Symbol] :web or :mcp — named in the log row
    # @return [Result]
    # @raise [ActiveRecord::RecordInvalid] when the session refuses the value
    #   (out of range, not an integer)
    def self.call(session:, precedence:, actor: :web)
      new(session: session, precedence: precedence, actor: actor).call
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
        session.update!(precedence: precedence)
        if previous != session.precedence
          session.logs.create!(
            content: "Precedence set#{ACTOR_LABELS.fetch(actor, '')} to #{session.precedence} (was #{previous})",
            level: "info"
          )
        end
      end

      Result.new(session: session, previous: previous, precedence: session.precedence)
    end
  end
end
