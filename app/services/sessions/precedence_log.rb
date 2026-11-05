# frozen_string_literal: true

module Sessions
  # The session log row for a rank a door typed or chose:
  # "Precedence set via MCP to 55 (was 10)". Written by Sessions::UpdatePrecedence
  # and Sessions::UpdateSchedulingClass.
  #
  # Called inside the caller's transaction, after its save, so a failed log write
  # undoes the write it describes. `previous` is the stored value, which the caller
  # read before saving, and a rank that did not move writes no row.
  #
  # Not a drag: Sessions::ReorderPrecedence's row says how the session got there
  # ("… by drag-and-drop in the Ranked view") and Sessions::ApplyUserViewOrder's
  # says where it landed, so each writes its own.
  module PrecedenceLog
    module_function

    # @param session [Session] saved, holding the new rank
    # @param previous [Integer] the rank stored before the save
    # @param label [String] from Sessions::ActorLabel
    # @return [Log, nil] the row, or nil when the rank did not move
    def write(session, previous:, label:)
      return if previous == session.precedence

      session.logs.create!(
        content: "Precedence set#{label} to #{session.precedence} (was #{previous})",
        level: "info"
      )
    end
  end
end
