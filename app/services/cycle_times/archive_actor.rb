# frozen_string_literal: true

module CycleTimes
  # Who archived a session, from the actor phrase its archive line carries.
  #
  # The phrase is written by the surface that performed the archive (see
  # SessionStateMachine#archive_actor and its callers), so this is a reading of
  # provenance Zimmer already records, not an inference from what the session
  # said. Four answers:
  #
  #   :agent       a session through the MCP API or the self-session server
  #                (declared or not — a human archives from the web UI, never
  #                over MCP), or the REST API, which only the fleet's shared API
  #                key reaches
  #   :human       the web UI's Trash button, or the Live Mode assistant acting
  #                for the person talking to it
  #   :system      one of Zimmer's own sweeps (stale-session, status-summary)
  #   :unrecorded  no actor was recorded
  module ArchiveActor
    module_function

    def classify(phrase)
      text = phrase.to_s
      return :human if text.match?(/\ba user in the web UI\b|\bLive Mode assistant\b/)
      return :system if text.start_with?("Zimmer's")
      return :agent if text.match?(/\Asession #\d+ via\b|\Aan undeclared .*caller(?: \(bulk\))?\z|\Athe REST API\b/)

      :unrecorded
    end

    # The archiving session's id, when the phrase names one ("session #12 via …").
    def session_id(phrase)
      phrase.to_s[/\Asession #(\d+) via\b/, 1]&.to_i
    end
  end
end
