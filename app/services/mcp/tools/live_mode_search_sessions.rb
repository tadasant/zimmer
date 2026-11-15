# frozen_string_literal: true

module Mcp
  module Tools
    # quick_search_sessions as the Live Mode assistant gets it (the `live_mode`
    # tool group).
    #
    # Somebody asking out loud for a session is looking for one they remember,
    # which is usually finished work, and finished work has archived itself. They
    # name it in their own words rather than as an exact title fragment. So this
    # variant always includes archived sessions and always matches every word in
    # any order (`match: all_words`). The base tool's defaults (no archived
    # sessions, one literal phrase) suit an agent's duplicate check and stay as
    # they are for every other caller.
    #
    # There is no transcript scan (`search_contents`). From Live Mode it was used
    # for paraphrases, which an exact-phrase scan cannot match: thirteen empty
    # multi-word scans in one conversation. A lookup that needs what was said is
    # a job for `quick_router`.
    #
    # Rows are short — title, id, status, when it last moved, the CarPlay fit —
    # because they are read aloud. `get_session` has the rest.
    class LiveModeSearchSessions < QuickSearchSessions
      tool_name "quick_search_sessions"

      ACCEPTED_ARGUMENTS = %w[id query status page per_page].freeze
      DEFAULT_PER_PAGE = 10
      MAX_PER_PAGE = 25

      EMPTY_RESULT_NOTE = "No session's title or metadata has every one of those words. That does not mean it does " \
                          "not exist: try fewer or other words (a name, a project, an issue number), or check " \
                          "`get_user_view`. This search cannot read what was said in a session; if that is what it " \
                          "takes, hand the question to `quick_router`."

      description <<~DESC
        Find sessions by a few words from their title or metadata (any order, archived included) or by id; it cannot search what was said in them.

        Use two or three distinctive words the person used: a name, a project, an issue or PR number. Every word
        must appear; more words narrow it. Finished work is archived, and it is included. Pass `id` to look one
        session up. Rows are short; call `get_session` for one in full.

        An empty result is not proof a session does not exist: try other words before saying so.
      DESC

      input_schema({
        type: "object",
        properties: {
          query: {
            type: "string",
            maxLength: MAX_QUERY_LENGTH,
            description: "Two or three distinctive words. Every one must appear in the title or metadata, in any order."
          },
          id: { type: "number", description: "Look up one session by id. Other arguments are ignored." },
          status: {
            oneOf: [
              { type: "string", enum: SessionsController::STATUS_FILTER_OPTIONS },
              { type: "array", items: { type: "string", enum: SessionsController::STATUS_FILTER_OPTIONS } }
            ],
            description: 'Optional: one status, or several. "needs_input" is waiting on the person.'
          },
          page: { type: "number", minimum: 1, description: "Page number. Default: 1" },
          per_page: {
            type: "number", minimum: 1, maximum: MAX_PER_PAGE,
            description: "Rows per page (1-#{MAX_PER_PAGE}). Default: #{DEFAULT_PER_PAGE}."
          }
        },
        required: []
      })

      def call(args)
        narrowed = args.slice(*ACCEPTED_ARGUMENTS)
        per_page = narrowed["per_page"].to_i
        narrowed["per_page"] = per_page.positive? ? per_page.clamp(1, MAX_PER_PAGE) : DEFAULT_PER_PAGE
        narrowed["show_archived"] = true
        narrowed["match"] = MATCH_ALL_WORDS

        result = super(narrowed)
        return result unless narrowed["id"].nil? && narrowed["query"].to_s.strip.present? && result.start_with?("No sessions found")

        "#{result}\n\n#{EMPTY_RESULT_NOTE}"
      end

      private

      # The short rows say what they leave out in one line, not the base tool's
      # paragraph about compact rows and scheduling fields.
      def compact_notice(_verbose)
        [ "*Short rows, for reading aloud. `get_session` has one session in full.*", "" ]
      end

      def format_session(session, paused: false, verbose: false)
        lines = [
          "### #{session.title} (ID: #{session.id})",
          "",
          "- **Status:** #{session.status}"
        ]
        if paused
          at = session.pending_wake_at
          lines << "- **Paused:** asleep #{at ? "until #{at.utc.iso8601}" : 'on a pending wake-up'}. " \
                   "#{Sessions::SleeperGuidance::FOLLOW_UP_STILL_WAKES}"
        end
        lines << "- **CarPlay fit:** #{session.carplay_fit_summary}" if session.carplay_fit_summary
        lines << "- **Updated:** #{session.updated_at.utc.iso8601} " \
                 "(#{ActionController::Base.helpers.time_ago_in_words(session.updated_at)} ago)"
        lines.join("\n")
      end
    end
  end
end
