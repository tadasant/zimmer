# frozen_string_literal: true

module Sessions
  # Renames a session by hand: writes `title`, drops the
  # `metadata["auto_generated_title"]` flag, and logs the change.
  #
  # Every surface that lets somebody rename a session routes through here: the
  # web UI's editable title (`PATCH /sessions/:id/update_title`), a `title` in
  # `PATCH /api/v1/sessions/:id`, and the `update_title` MCP action (which
  # `SelfSessionActionSession` inherits). One writer is what keeps the doors
  # agreeing on the cap, on what is refusable, and — the part that matters — on
  # the flag: SessionTitleJob re-titles a session only while
  # `auto_generated_title` is true, so a rename that left it behind would be
  # quietly overwritten by the next titling run.
  #
  # The rules:
  # - The title is stripped of surrounding whitespace, then stored.
  # - Blank (nil, "", or whitespace only) is refused: a session always has a title.
  # - Longer than Session::TITLE_MAX_LENGTH characters is refused.
  # - A value that is not a String is refused rather than coerced.
  #
  # Not a writer of generated titles: SessionTitleJob and WorkBacklog::Start set
  # titles of their own and manage the flag themselves.
  #
  # Scope: one `update!` on `title`, a narrow `remove_metadata!`, and one log row.
  # The flag is dropped after the title lands, so a refused write leaves it alone.
  class UpdateTitle
    class Error < StandardError; end

    # @param session [Session]
    # @param title [String]
    # @return [Session] the updated session
    # @raise [Error] on a blank, over-long or non-String title
    # @raise [ActiveRecord::RecordInvalid] when the session fails another validation
    def self.call(session:, title:)
      new(session: session, title: title).call
    end

    def initialize(session:, title:)
      @session = session
      @title = title
    end

    attr_reader :session, :title

    def call
      raise Error, "Title must be a string" unless title.nil? || title.is_a?(String)

      stripped = title.to_s.strip
      raise Error, "Title cannot be empty" if stripped.empty?
      if stripped.length > Session::TITLE_MAX_LENGTH
        raise Error, "Title is too long (maximum #{Session::TITLE_MAX_LENGTH} characters)"
      end

      session.update!(title: stripped)
      session.remove_metadata!("auto_generated_title")
      session.logs.create!(content: "Session title updated to: #{stripped}", level: "info")
      session
    end
  end
end
