# frozen_string_literal: true

module Sessions
  # Changes a session's auto-compact (context) window, `auto_compact_window`.
  #
  # Every surface that changes it on an existing session routes through here: the
  # web UI's context-window editor (`PATCH /sessions/:id/update_auto_compact_window`)
  # and the `change_auto_compact_window` MCP action. The REST API sets it only at
  # creation. The window reaches Claude Code as CLAUDE_CODE_AUTO_COMPACT_WINDOW at
  # spawn time, so it applies from the next turn or restart; the running process
  # keeps the window it was started with.
  #
  # The rules:
  # - The value must be a positive integer, as an Integer or a string of digits.
  #   Blanks, decimals, negatives and words are refused.
  # - It must be between 1 and Session::MAX_AUTO_COMPACT_WINDOW, the bounds the
  #   Session validates at creation.
  # - The window the session already has is a no-op: no write, no log.
  #
  # It touches only `auto_compact_window` and one log row, written together in one
  # transaction. It does not restart the session or signal the running process.
  class UpdateAutoCompactWindow
    class Error < StandardError; end
    # The value is missing or is not an integer.
    class InvalidParameter < Error; end
    # The value is an integer outside 1..Session::MAX_AUTO_COMPACT_WINDOW.
    class OutOfRange < Error; end

    ACTOR_LABELS = { web: "", mcp: " via MCP" }.freeze

    # @param session [Session]
    # @param auto_compact_window [Integer, String] the window in tokens
    # @param actor [Symbol] :web or :mcp — named in the log row
    # @return [Session]
    # @raise [InvalidParameter] when the value is not an integer
    # @raise [OutOfRange] when the value is outside the allowed bounds
    # @raise [ActiveRecord::RecordInvalid] when the session refuses the change
    def self.call(session:, auto_compact_window:, actor: :web)
      new(session: session, auto_compact_window: auto_compact_window, actor: actor).call
    end

    def initialize(session:, auto_compact_window:, actor:)
      @session = session
      @auto_compact_window = auto_compact_window
      @actor = actor
    end

    attr_reader :session, :auto_compact_window, :actor

    def call
      raise InvalidParameter, "auto_compact_window must be a positive integer" unless auto_compact_window.to_s.match?(/\A\d+\z/)

      new_window = auto_compact_window.to_i
      unless new_window.between?(1, Session::MAX_AUTO_COMPACT_WINDOW)
        raise OutOfRange, "auto_compact_window must be between 1 and #{Session::MAX_AUTO_COMPACT_WINDOW}"
      end

      # Compared against the stored value, not the in-memory one: a write that
      # failed and is being retried (the web door's with_db_retry) leaves the new
      # window on the object, and that retry must still write it.
      old_window = session.attribute_in_database("auto_compact_window")
      return session if old_window == new_window

      session.transaction do
        session.update!(auto_compact_window: new_window)
        session.logs.create!(
          content: "Context window updated#{ACTOR_LABELS.fetch(actor, '')} (#{old_window} → #{new_window}); applies on next turn or restart",
          level: "info"
        )
      end
      session
    end
  end
end
