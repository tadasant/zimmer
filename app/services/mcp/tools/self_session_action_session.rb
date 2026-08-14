# frozen_string_literal: true

module Mcp
  module Tools
    # The action_session a session gets pointed at *itself* (the self_session
    # tool group). Same tool name and the same action bodies as ActionSession —
    # only the self-management subset is exposed, so a session cannot drive other
    # sessions' lifecycles through the server injected into it.
    class SelfSessionActionSession < ActionSession
      tool_name "action_session"

      ACTIONS = %w[update_notes update_title set_heartbeat archive].freeze

      SELF_ACTION_DESC = 'Action to perform: "update_notes", "update_title", "set_heartbeat", "archive"'

      description <<~DESC
        Perform a self-management action on a session.

        **Actions (limited to self-management):**
        - **update_notes**: Update the notes on a session (requires "session_notes")
        - **update_title**: Update the title of a session (requires "title")
        - **set_heartbeat**: Toggle this session's own heartbeat and/or set its interval (provide "enabled" and/or "interval_seconds"). When the heartbeat is enabled and this session sits in needs_input, a recurring nudge prompts it to keep working toward its goal. If you are genuinely blocked or done, set "enabled" to false to stop the nudges.
        - **archive**: Archive a session (marks as completed)

        **Use cases:**
        - Update session notes to record progress or context
        - Set a meaningful session title
        - Turn off this session's heartbeat when blocked or finished (set_heartbeat with enabled=false)
        - Archive the session when work is complete

        **Archive guidelines:**
        - Self-archival is how a session signals it ran to completion, so archiving is the normal ending — not something that needs a specific instruction to permit it
        - Sessions in `needs_input` appear on the user's homepage as their action queue, so staying there is a claim on a person's attention. Make it only for one of the four sanctioned reasons in the Session Lifecycle Management section of your system prompt: you lacked the scope or tools to finish and have no parent to report back to; you are holding a PR whose merge disposition is unsettled; a human invoked this session to explore something or answer a question; or, rarely, you hit an ambiguity too dangerous and too irreversible to guess at
        - "The user should read this" is not one of them. Put it in your final message, or in a Slack channel if the outcome is a read-only FYI and you have a Slack server, and archive — an archived session's transcript stays readable
        - A session that opened a PR is the exception to the timing: stay in `needs_input` until that PR merges. Zimmer's pull-request poller reaches unarchived sessions only, and it delivers a message on the open → merged transition — that message is the signal to archive. A PR a merge gate holds sends none until a human merges it, which is how the session stays in the queue for that human. If Zimmer recorded no PR URL for the session, no message can ever arrive — report the URL and archive rather than waiting
        - Anything you noticed but could not fix belongs in a GitHub issue, not in a parked session. File it, then archive
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: SESSION_ID_DESC
          },
          action: { type: "string", enum: ACTIONS, description: SELF_ACTION_DESC },
          session_notes: { type: "string", description: SESSION_NOTES_DESC },
          title: { type: "string", description: TITLE_DESC },
          enabled: { type: "boolean", description: ENABLED_DESC },
          interval_seconds: { type: "number", description: INTERVAL_SECONDS_DESC }
        },
        required: [ "session_id", "action" ]
      })

      private

      def allowed_actions
        ACTIONS
      end
    end
  end
end
