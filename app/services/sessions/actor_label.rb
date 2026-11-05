# frozen_string_literal: true

module Sessions
  # How a session's log row names the door a change came through: nothing for
  # the web UI, " via MCP" or " via the REST API" otherwise. The words go straight
  # after the verb, so "Precedence set via MCP to 55 (was 10)".
  #
  # Shared by Sessions::UpdatePrecedence, Sessions::UpdateSchedulingClass and
  # Sessions::UpdateGoal. Other services keep their own labels because theirs
  # differ: Sessions::ReorderPrecedence and the restart and transcript rows use a
  # different phrase in a different place, Sessions::UpdateEffort, UpdateModel and
  # UpdateCatalogSelection say " via API" under an `:api` actor, and
  # UpdateAutoCompactWindow and UpdateMemoryBoost have no `:rest` and fall back to
  # no label on an unknown actor.
  #
  # The lookup is strict, and each writer does it before its first write, so an
  # actor that is not one of these raises KeyError with nothing written.
  module ActorLabel
    LABELS = { web: "", mcp: " via MCP", rest: " via the REST API" }.freeze

    module_function

    # @param actor [Symbol] :web, :mcp or :rest
    # @return [String] the label, with its leading space when it has words
    # @raise [KeyError] on any other actor
    def for(actor)
      LABELS.fetch(actor)
    end
  end
end
