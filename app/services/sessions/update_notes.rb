# frozen_string_literal: true

module Sessions
  # Writes a session's notes — `session_notes` and its `session_notes_updated_at`
  # stamp — and nothing else.
  #
  # Every surface that lets somebody edit them routes through here: the web UI's
  # notes panel (`PATCH /sessions/:id/update_notes`), `PATCH
  # /api/v1/sessions/:id/notes`, and the `update_notes` MCP action (which
  # `SelfSessionActionSession` inherits). One writer is what keeps the doors
  # agreeing on the cap, on what clears the notes, and on what is refusable.
  #
  # The rules:
  # - Blank (nil, "", or whitespace only) CLEARS the notes and the stamp. A
  #   blank value is stored as nil, so it is never measured against the cap.
  # - Anything else is stored verbatim, stamped with the current time, and
  #   refused when longer than Session::NOTES_MAX_LENGTH characters.
  # - A value that is not a String (a number or an object in a JSON body) is
  #   refused rather than coerced.
  #
  # Whether an ABSENT parameter means "clear" is the surface's call, not this
  # service's: the web and REST doors pass nil through and so clear, while the
  # MCP action refuses a missing `session_notes` before it gets here.
  #
  # Scope: ONE `update!` on two columns. Retry-safe — a second attempt writes
  # the same values. `Session#should_broadcast_to_index?` notices the notes going
  # blank or non-blank on its own.
  class UpdateNotes
    class Error < StandardError; end

    # Notes over the cap. Distinct from Error so the REST API can keep answering
    # it with its "Too long" classification, and an unreadable value with
    # "Validation failed".
    class TooLong < Error; end

    # @param session [Session]
    # @param notes [String, nil] blank clears
    # @return [Session] the updated session
    # @raise [TooLong] on notes over the cap
    # @raise [Error] on a non-String value
    def self.call(session:, notes:)
      new(session: session, notes: notes).call
    end

    def initialize(session:, notes:)
      @session = session
      @notes = notes
    end

    attr_reader :session, :notes

    def call
      raise Error, "session_notes must be a string." unless notes.nil? || notes.is_a?(String)

      stored = notes.presence
      if stored && stored.length > Session::NOTES_MAX_LENGTH
        raise TooLong, "Notes are too long (maximum #{Session::NOTES_MAX_LENGTH.to_fs(:delimited)} characters)"
      end

      session.update!(session_notes: stored, session_notes_updated_at: stored ? Time.current : nil)
      session
    end
  end
end
