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
        - Only self-archive when explicitly instructed to (e.g., a goal says "archive yourself")
        - Subagents that report results back to a parent agent via a tool call may self-archive, since no human needs to read the session output directly
        - Do NOT self-archive if a human user needs to read your output. Sessions in `needs_input` appear on the user's homepage — archiving removes them before the user can see your work. If your work product is a message the user should read, let the session stay in `needs_input`
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
